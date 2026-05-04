#lang scribble/manual

@(require (for-label rack-llm racket/base))

@title{rack-llm}

@defmodule[rack-llm]

A small grammar-first library for programming with LLMs in Racket.

The public API is intentionally small:

@itemlist[
 @item{@racket[define-grammar], @racket[emit], @racket[gen], @racket[select], @racket[pick] for constructive generation.}
 @item{@racket[best-of], @racket[weighted], @racket[weighted-score], @racket[pass], @racket[fail], @racket[abstain] for review and ranking.}
 @item{@racket[run], @racket[chat], @racket[system], @racket[user], @racket[assistant] for chat execution.}
]
