# SearchablePDFs

[![Build Status](https://github.com/ericphanson/SearchablePDFs.jl/workflows/CI/badge.svg)](https://github.com/ericphanson/SearchablePDFs.jl/actions)
[![Coverage](https://codecov.io/gh/ericphanson/SearchablePDFs.jl/branch/master/graph/badge.svg)](https://codecov.io/gh/ericphanson/SearchablePDFs.jl)

I had been using  [pdfsandwich](http://www.tobias-elze.de/pdfsandwich/) to
create searchable PDFs from non-searchable PDFs. However, it's a pain to collect
all the dependencies if e.g. you don't have root access. So I thought to package
them up with Julia's BinaryBuilder to make installation simple. However, I
wasn't able to cross-compile `pdfsandwich` itself. But since tesseract is doing
the hard work anyway, I thought I would just write the glue script myself. It
turns out there are [several of
these](https://github.com/tesseract-ocr/tessdoc/blob/master/User-Projects-%E2%80%93-3rdParty.md#a-pdf-to-searchable-pdf-tools)
already.

I believe I have likely diverged from the `pdfsandwich` implementation since I
haven't used ImageMagick's `convert` which is one of the dependencies of
`pdfsandwich`. Since the job can be done very simply, e.g.

  1. convert each page of the PDF to an image
  2. possibly clean it up with `unpaper`
  3. use tesseract to create a single-page searchable PDF
  4. combine the PDFs,

I decided to not look at the source of `pdfsandwich` when creating my implementation so I can stick to an MIT
license, which is the usual one in the Julia community.

## Status

It more-or-less works on the test file, although it produces a lot of text
output and warnings.

Next steps:

* Clean up the warnings and suppress or log the output
* Allow choice of training data used for tesseract
* Look at what settings should be used for `unpaper`
* Allow customizing the number of tasks spawned
* Robustify and test on more files
* Add better tests?

## Usage

```julia
using SearchablePDFs
file = ocr("test/test_rasterized.pdf")
```
