require "spec"
require "../src/github_mirror"

# Only the pure functions are tested here. The I/O paths (enumerate_repos,
# run_git, sync_repo, read_token) call out to the network, git, the
# filesystem, and exit() — they're validated by running the tool against real
# GitHub/git, not by mocking, which would only assert that the mocks behave
# like the mocks. The two functions below are pure input -> output with real
# branching and edge cases, which is exactly where unit tests earn their keep.

# A small helper to build Repo fixtures without hand-writing JSON each time.
private def repo(name : String, fork : Bool = false, archived : Bool = false) : Repo
  Repo.from_json({
    full_name: name,
    clone_url: "https://github.com/#{name}.git",
    fork:      fork,
    archived:  archived,
  }.to_json)
end

describe GithubMirror do
  describe "#parse_next_link" do
    it "returns nil when the header is nil (no Link header on the response)" do
      GithubMirror.parse_next_link(nil).should be_nil
    end

    it "returns nil for an empty string" do
      GithubMirror.parse_next_link("").should be_nil
    end

    it "extracts the next URL from a two-rel header" do
      header = %(<https://api.github.com/user/repos?page=2>; rel="next", ) +
               %(<https://api.github.com/user/repos?page=5>; rel="last")
      GithubMirror.parse_next_link(header)
        .should eq("https://api.github.com/user/repos?page=2")
    end

    it "returns nil on the last page (only prev/first rels, no next)" do
      # This is the loop-termination case: GitHub drops rel=\"next\" on the
      # final page. If this returned non-nil, pagination would never end.
      header = %(<https://api.github.com/user/repos?page=4>; rel="prev", ) +
               %(<https://api.github.com/user/repos?page=1>; rel="first")
      GithubMirror.parse_next_link(header).should be_nil
    end

    it "finds next when it is not the first rel listed" do
      header = %(<https://api.github.com/user/repos?page=1>; rel="prev", ) +
               %(<https://api.github.com/user/repos?page=3>; rel="next")
      GithubMirror.parse_next_link(header)
        .should eq("https://api.github.com/user/repos?page=3")
    end

    it "handles a single next rel with no other sections" do
      header = %(<https://api.github.com/user/repos?page=2>; rel="next")
      GithubMirror.parse_next_link(header)
        .should eq("https://api.github.com/user/repos?page=2")
    end

    it "ignores a malformed part with no rel parameter" do
      header = %(<https://api.github.com/user/repos?page=2>)
      GithubMirror.parse_next_link(header).should be_nil
    end

    it "does not match a rel that merely contains 'next' as a substring" do
      # rel=\"nextpage\" is not rel=\"next\" — guards against a sloppy
      # substring match sneaking in during a future refactor.
      header = %(<https://api.github.com/user/repos?page=2>; rel="nextpage")
      GithubMirror.parse_next_link(header).should be_nil
    end
  end

  describe "#select_repos" do
    it "keeps a plain repo (not a fork, not archived) under default filters" do
      result = GithubMirror.select_repos([repo("Lillevang/infra")], false, true)
      result.map(&.full_name).should eq(["Lillevang/infra"])
    end

    it "drops forks when include_forks is false (the default)" do
      repos = [repo("Lillevang/mine"), repo("Lillevang/aforked", fork: true)]
      result = GithubMirror.select_repos(repos, false, true)
      result.map(&.full_name).should eq(["Lillevang/mine"])
    end

    it "keeps forks when include_forks is true" do
      repos = [repo("Lillevang/mine"), repo("Lillevang/aforked", fork: true)]
      result = GithubMirror.select_repos(repos, true, true)
      result.map(&.full_name).should eq(["Lillevang/mine", "Lillevang/aforked"])
    end

    it "keeps archived repos by default (include_archived true)" do
      # Archived repos are exactly what a backup wants to preserve.
      repos = [repo("Lillevang/old", archived: true)]
      result = GithubMirror.select_repos(repos, false, true)
      result.map(&.full_name).should eq(["Lillevang/old"])
    end

    it "drops archived repos when include_archived is false" do
      repos = [repo("Lillevang/live"), repo("Lillevang/old", archived: true)]
      result = GithubMirror.select_repos(repos, false, false)
      result.map(&.full_name).should eq(["Lillevang/live"])
    end

    it "drops a repo that is both a fork and archived when both are excluded" do
      repos = [repo("Lillevang/both", fork: true, archived: true)]
      GithubMirror.select_repos(repos, false, false).should be_empty
    end

    it "keeps a fork-and-archived repo only when both flags are enabled" do
      repos = [repo("Lillevang/both", fork: true, archived: true)]
      result = GithubMirror.select_repos(repos, true, true)
      result.map(&.full_name).should eq(["Lillevang/both"])
    end

    it "returns an empty array unchanged" do
      GithubMirror.select_repos([] of Repo, false, true).should be_empty
    end
  end
end
