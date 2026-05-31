require "log"
require "base64"
require "http/client"
require "json"

struct Repo
  include JSON::Serializable
  property full_name : String
  property clone_url : String
  property fork : Bool
  property archived : Bool
end

struct RepoState
  include JSON::Serializable
  property last_attempt : String
  property last_status : String
  property last_success :  String?

  def initialize(@last_attempt, @last_status, @last_success = nil)
  end
end

struct MirrorState
  include JSON::Serializable
  property repos :  Hash(String, RepoState)
  property last_run : String?
  property last_run_repo_count : Int32?
  property last_run_failures : Int32?
  property last_run_ok : Bool?

  def initialize
    @repos = Hash(String, RepoState).new
  end
end

module GithubMirror
  extend self

  VERSION = "0.1.0"
  GITHUB_API = "https://api.github.com"

  def now_iso : String
    Time.utc.to_rfc3339(fraction_digits: 0)
  end

  def env_bool(name : String, default : Bool) : Bool
    bool_vals = Set{"1", "true", "yes", "on"}
    unless ENV.has_key?(name)
      Log.info{"#{name}: #{default}"}
      return default
    end
    Log.info{"#{name}: #{ENV[name]}"}
    return bool_vals === ENV[name].downcase
  end

  def read_token() : String
    unless ENV.has_key?("GH_TOKEN_FILE")
      Log.fatal{"GH_TOKEN_FILE is not set"}
      exit(2)
    end
    path = ENV["GH_TOKEN_FILE"]
    token = begin
      File.read(Path[path]).strip()
    rescue ex : File::NotFoundError | File::AccessDeniedError | IO::Error
      Log.fatal{"cannot read token file #{ENV["GH_TOKEN_FILE"]}"}
      exit(2)
    end
    if token.empty?
      Log.fatal { "token file #{path} is empty "}
      exit(2)
    end
    Log.info { "Github Token loaded" }
    token
  end

  def git_auth_env(token : String) : Hash(String, String)
    e = Hash(String, String).new
    basic = Base64.strict_encode("x-access-token:#{token}")
    ENV.each {  |k, v| e[k] = v }
    e["GIT_CONFIG_COUNT"] = "2"
    e["GIT_CONFIG_KEY_0"] = "http.extraHeader"
    e["GIT_CONFIG_VALUE_0"] = "AUTHORIZATION: basic #{basic}"
    e["GIT_CONFIG_KEY_1"] = "safe.directory"
    e["GIT_CONFIG_VALUE_1"] = "*"
    e["GIT_TERMINAL_PROMPT"] = "0"
    e
  end

  # Returns the  rel="next" URL from a GitHub Link header, or nil when there's no next page (ending pagination loop)
  def parse_next_link(link : String?) : String?
    return nil unless link
    link.split(",").each do |part|
      sections = part.split(";")
      next if sections.size < 2
      target = sections[0].strip.strip("<>")
      sections[1..].each do |param|
        kv = param.strip.split("=", 2)
        next unless kv.size == 2
        return target if kv[0] == "rel" && kv[1].strip.strip('"') == "next"
      end
    end
    nil
  end

  # Enumerate every repo the token can see, following pagination to exhaustion
  # Any API failure is fatal: abort rather than risk acting on a partial or
  # empty list (can't list repos must never be read as not having any repos)
  def enumerate_repos(token : String) : Array(Repo)
    affiliation = ENV.fetch("GH_AFFILIATION", "owner")
    visibility = ENV.fetch("GH_VISIBILITY", "all")
    url : String? = "#{GITHUB_API}/user/repos?per_page=100&affiliation=#{affiliation}&visibility=#{visibility}"

    repos =  Array(Repo).new
    page_no = 0

    while current = url
      page_no += 1

      headers = HTTP::Headers.new
      headers["Authorization"] = "Bearer #{token}"
      headers["Accept"] = "application/vnd.github+json"
      headers["X-GitHub-Api-Version"] = "2022-11-28"
      headers["User-Agent"] = "github-mirror-backup"

      response = begin
        HTTP::Client.get(current, headers: headers)
      rescue ex : IO::Error
        Log.fatal{ "cannot  reach GitHub API on page #{page_no}: #{ex.message}"}
        exit(1)
      end

      unless response.success?
        Log.fatal{ "GitHub API #{response.status_code} on page #{page_no}: #{response.body}"}
        exit(1)
      end

      page =  begin
        Array(Repo).from_json(response.body)
      rescue ex : JSON::ParseException
        Log.fatal{ "could not parse API response on page #{page_no}: #{ex.message}"}
        exit(1)
      end

      repos.concat(page)
      url = parse_next_link(response.headers["Link"]?)
    end

    repos
  end


  # Run a git subprocess with the given environment. Returns {success, error}.
  #
  # TODO: cancel the timeout timer on completion before adding the concurrent clone pool.
  # As written, a fast-finishing git leaves a fiber sleeping the full timeout; harmless when sequential, but N sleepers
  # accumulate under concurrency. Replace with a Chhannel/select-based cancellation then.
  def run_git(args : Array(String), env : Hash(String, String), timeout : Int32?) : {Bool, String}
    stdout = IO::Memory.new
    stderr = IO::Memory.new

    process = Process.new(
      "git", args,
      env: env,
      output: stdout,
      error: stderr,
      input: Process::Redirect::Close,
    )

    if timeout
      spawn do
        sleep timeout.seconds
        process.terminate(graceful: false) unless process.terminated?
      rescue
      # Process gone, nothing to do
      end
    end

    status = process.wait

    unless status.success?
      if timeout && status.signal_exit?
        return {false, "timed out after #{timeout}s (or killed by signal)"}
      end
      msg = stderr.to_s.strip
      msg = stdout.to_s.strip if msg.empty?
      msg = "git exited #{status.exit_code}" if msg.empty?
      return {false, msg}
    end

    {true, ""}
  rescue ex : IO::Error | RuntimeError
    {false, "could not exec git: #{ex.message}"}
  end

  def sync_repo(repo : Repo, mirror_root : Path, env : Hash(String, String), timeout : Int32?, fetch_lfs : Bool) : Bool
    dest = mirror_root/"#{repo.full_name}.git"

    action = Dir.exists?(dest) ? "update" : "clone"

    ok, err = begin
      if action == "update"
        run_git(["-C", dest.to_s, "remote", "update", "--prune"], env, timeout)
      else
        Dir.mkdir_p(dest.parent)
        run_git(["clone", "--mirror", repo.clone_url, dest.to_s], env, timeout)
      end
    rescue ex : File::Error
      {false, "filesystem error: #{ex.message}"}
    end
    if ok && fetch_lfs
      ok, err = run_git(["-C", dest.to_s, "lfs", "fetch", "--all"], env, timeout)
      err = "lfs fetch failed: #{err}" unless ok
    end

    if ok
      Log.info { "OK   #{action.ljust(6)} #{repo.full_name}" }
    else
      Log.error { "FAIL   #{action.ljust(6)} #{repo.full_name}: #{err}" }
    end
    ok
  end

  def load_state(path : Path) : MirrorState
    return MirrorState.new unless File.exists?(path)
    begin
      MirrorState.from_json(File.read(path))
    rescue ex : JSON::ParseException
      Log.warn { "could not parse existing state #{path}, starting fresh: #{ex.message}" }
      MirrorState.new
    end
  end

  def select_repos(repos : Array(Repo), include_forks : Bool, include_archived : Bool) : Array(Repo)
    repos.reject do |r|
      (r.fork && !include_forks) || (r.archived && !include_archived)
    end
  end

  def main
    Log.info{"Github Mirror started"}
    Log.info{"Loading configuration"}
    mirror_root = Path[ENV.fetch("MIRROR_DIR", "/data")]
    Dir.mkdir_p(mirror_root)

    include_forks = env_bool("INCLUDE_FORKS", false)
    include_archived = env_bool("INCLUDE_ARCHIVED", true)
    fetch_lfs = env_bool("FETCH_LFS", false)
    timeout = ENV["GIT_TIMEOUT"]?.try(&.to_i32?)
    Log.info{"Timeout: #{timeout}"}

    token = read_token()
    auth_env = git_auth_env(token)
    Log.info{"Configuration loaded successfully!"}
    Log.info{"Enumerating repos..."}
    repos = enumerate_repos(token)
    Log.info{"Enumeration returned #{repos.size} repositories"}
    selected = select_repos(repos, include_forks, include_archived)
    skipped = repos.size - selected.size
    Log.info{"Skipped #{skipped} repositories (fork/archived filters)"}

    state_path = mirror_root/"mirror-state.json"
    state = load_state(state_path)
    run_ts = now_iso()

    failures = 0
    selected.each do |r|
      ok = sync_repo(r, mirror_root, auth_env, timeout, fetch_lfs)

      entry = state.repos[r.full_name]?
      if entry
        entry.last_attempt = run_ts
        entry.last_status = ok ? "ok" : "failed"
        entry.last_success = run_ts if ok
      else
        entry = RepoState.new(
          last_attempt: run_ts,
          last_status: ok ? "ok" : "failed",
          last_success: ok ? run_ts : nil
        )
      end
      state.repos[r.full_name] = entry

      failures += 1 unless ok
    end

    state.last_run = run_ts
    state.last_run_repo_count = selected.size
    state.last_run_failures = failures
    state.last_run_ok = failures == 0

    begin
      File.write(state_path, state.to_json)
    rescue ex : IO::Error
      Log.warn { "could not write state file #{state_path}: #{ex.message}" }
    end

    if failures > 0
      Log.error { "DONE with #{failures}/#{selected.size} failures" }
      exit(1)
    end
    Log.info { "DONE: #{selected.size} repositories mirrored cleanly" }
  end
end

