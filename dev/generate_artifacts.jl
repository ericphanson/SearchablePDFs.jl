# Modified from https://github.com/r3tex/ObjectDetector.jl/blob/master/dev/artifacts/generate_artifacts.jl
# First, run `download_data.jl` from the `/dev` directory to download the files into `/data`
# Then run this file to upload them to Github releases and populate `/Artifacts.toml`

using Pkg.Artifacts, LibGit2, ghr_jll

deploy = true
if deploy && !haskey(ENV, "GITHUB_TOKEN")
    error("For automatic github deployment, export GITHUB_TOKEN!")
end

data_dir = joinpath(@__DIR__, "..", "data")

if deploy
    # Where we will put our tarballs
    tmpdir = mktempdir()

    function get_git_remote_url(repo_path::String)
        repo = LibGit2.GitRepo(repo_path)
        origin = LibGit2.get(LibGit2.GitRemote, repo, "origin")
        return LibGit2.url(origin)
    end

    # Try to detect where we should upload these weights to (or just override
    # as shown in the commented-out line)
    origin_url = get_git_remote_url(dirname(@__DIR__))
    deploy_repo = "$(basename(dirname(origin_url)))/$(basename(origin_url))"
    #deploy_repo = "staticfloat/ObjectDetector.jl"

    tag = "traineddata"
end

for dir in readdir(data_dir)
    weightsfiles = filter(x->endswith(x,".traineddata"), readdir(joinpath(data_dir, dir)))
    
    @info("Generating artifact for $(dir)")
    # Create a local artifact
    hash = create_artifact() do artifact_dir
        # Copy in weights
        for weightsfile in weightsfiles
            cp(joinpath(data_dir, dir, weightsfile), joinpath(artifact_dir, weightsfile))
        end
        # Copy in the license
        cp(joinpath(data_dir, dir, "LICENSE"), joinpath(artifact_dir, "LICENSE"))
        # Copy in the `pdf.ttf` file
        cp(joinpath(data_dir, dir, "pdf.ttf"), joinpath(artifact_dir, "pdf.ttf"))

    end

    # Spit tarballs to be hosted out to local temporary directory:
    if deploy
        tarball_hash = archive_artifact(hash, joinpath(tmpdir, "$(dir).tar.gz"))

        # Calculate tarball url
        tarball_url = "https://github.com/$(deploy_repo)/releases/download/$(tag)/$(dir).tar.gz"

        # Bind this to an Artifacts.toml file
        @info("Binding $(dir) in Artifacts.toml...")
        bind_artifact!(joinpath(@__DIR__, "..", "Artifacts.toml"), dir, hash; download_info=[(tarball_url, tarball_hash)], lazy=true, force=true)
    end
end

if deploy
    # Upload tarballs to a special github release
    @info("Uploading tarballs to $(deploy_repo) tag `$(tag)`")
    ghr() do ghr_exe
        run(`$ghr_exe -replace -u $(dirname(deploy_repo)) -r $(basename(deploy_repo)) $(tag) $(tmpdir)`)
    end

    @info("Artifacts.toml file now contains all bound artifact names")
    rm(tmpdir; force=true, recursive=true)
end
