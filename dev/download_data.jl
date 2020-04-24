# Run this file to download the trained data to `/data`
using HTTP
repos = ["tessdata", "tessdata_fast", "tessdata_best"]
names = ["eng", "equ"]

does_not_exist = [("tessdata_best", "equ")]

data_dir = joinpath(@__DIR__, "..", "data")
isdir(data_dir) || mkdir(data_dir)

for repo in repos
    dir = joinpath(data_dir, repo)
    isdir(dir) || mkdir(dir)

    # Download license
    path = joinpath(dir, "LICENSE")
    url = "https://raw.githubusercontent.com/tesseract-ocr/tessdata/master/LICENSE"
    HTTP.download(url, path)

    # Download `pdf.ttf`
    path = joinpath(dir, "pdf.ttf")
    url = "https://github.com/tesseract-ocr/tessconfigs/raw/master/pdf.ttf"
    HTTP.download(url, path)

    # Download data files
    for name in names
        (repo, name) ∈ does_not_exist && continue
        path = joinpath(dir, name) * ".traineddata"
        url = "https://github.com/tesseract-ocr/$repo/raw/master/$name.traineddata"
        @info "Downloading" repo name
        HTTP.download(url, path)
    end
end
