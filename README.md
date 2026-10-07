Name
====

nginx-zstd-module - two nginx modules for [Zstandard](https://facebook.github.io/zstd/):
one that compresses a response on the fly, one that serves a `.zst` file
that is already there.

[![Build & Test][build-test-badge]][build-test-link]
[![FreeBSD][freebsd-badge]][freebsd-link]
[![Round trip][roundtrip-badge]][roundtrip-link]
[![A/UBSan][sanitizers-badge]][sanitizers-link]
[![Valgrind][valgrind-badge]][valgrind-link]
[![CodeQL][codeql-badge]][codeql-link]
[![Lint][lint-badge]][lint-link]

[build-test-badge]: https://github.com/joneum/nginx-zstd-module/actions/workflows/build-test.yml/badge.svg
[build-test-link]: https://github.com/joneum/nginx-zstd-module/actions/workflows/build-test.yml
[freebsd-badge]: https://github.com/joneum/nginx-zstd-module/actions/workflows/freebsd.yml/badge.svg
[freebsd-link]: https://github.com/joneum/nginx-zstd-module/actions/workflows/freebsd.yml
[roundtrip-badge]: https://github.com/joneum/nginx-zstd-module/actions/workflows/roundtrip.yml/badge.svg
[roundtrip-link]: https://github.com/joneum/nginx-zstd-module/actions/workflows/roundtrip.yml
[sanitizers-badge]: https://github.com/joneum/nginx-zstd-module/actions/workflows/sanitizers.yml/badge.svg
[sanitizers-link]: https://github.com/joneum/nginx-zstd-module/actions/workflows/sanitizers.yml
[valgrind-badge]: https://github.com/joneum/nginx-zstd-module/actions/workflows/valgrind.yml/badge.svg
[valgrind-link]: https://github.com/joneum/nginx-zstd-module/actions/workflows/valgrind.yml
[codeql-badge]: https://github.com/joneum/nginx-zstd-module/actions/workflows/codeql.yml/badge.svg
[codeql-link]: https://github.com/joneum/nginx-zstd-module/actions/workflows/codeql.yml
[lint-badge]: https://github.com/joneum/nginx-zstd-module/actions/workflows/lint.yml/badge.svg
[lint-link]: https://github.com/joneum/nginx-zstd-module/actions/workflows/lint.yml

        * [zstd](#zstd)
        * [zstd_buffers](#zstd_buffers)
        * [zstd_comp_level](#zstd_comp_level)
        * [zstd_dict_file](#zstd_dict_file)
        * [zstd_min_length](#zstd_min_length)
        * [zstd_types](#zstd_types)
    * [ngx_http_zstd_static_module](#ngx_http_zstd_static_module)
        * [zstd_static](#zstd_static)
* [Variables](#variables)
    * [$zstd_ratio](#zstd_ratio)
* [Compatibility](#compatibility)
* [Test Suite](#test-suite)
* [License](#license)

Description
===========

nginx compresses with gzip, and since 1.11 it can hand out a `.gz` file
that somebody prepared earlier.  These two modules do the same with
Zstandard, which reaches a comparable ratio at a fraction of the CPU
cost and is understood by every current browser.

`ngx_http_zstd_filter_module` is an output filter.  It sits in the
filter chain next to the gzip filter, picks up a response whose type is
listed in `zstd_types`, and compresses it when the client announced
`zstd` in `Accept-Encoding`.

`ngx_http_zstd_static_module` never compresses anything.  For a request
to `/style.css` it looks for `/style.css.zst` and sends that instead,
with `Content-Encoding: zstd`.  It calls into no library at all.

Status
======

In production use.  The modules build against every nginx release listed
under [Compatibility](#compatibility) and the suite runs on each of them,
on Linux and on FreeBSD.

Synopsis
========

```nginx
# an external dictionary, if both ends agree on one
zstd_dict_file /path/to/dict;

server {
    listen 127.0.0.1:8080;

    location / {
        zstd on;
        zstd_min_length 256;
        zstd_comp_level 3;

        proxy_pass http://backend;
    }
}

server {
    listen 127.0.0.1:8081;

    location / {
        zstd_static on;
        root html;
    }
}
```

Installation
============

Build nginx with the modules compiled in:

```
./configure --add-module=/path/to/nginx-zstd-module
make
make install
```

`ci/build.sh` does the same thing for a throwaway nginx, which is handy
for trying a patch out:

```
ci/build.sh 1.31.6 /tmp/nginx-test
/tmp/nginx-test/sbin/nginx -V
```

Building as a dynamic module
----------------------------

```
./configure --add-dynamic-module=/path/to/nginx-zstd-module
make modules
```

Both modules are built, and both have to be loaded before their
directives can be used:

```nginx
load_module modules/ngx_http_zstd_filter_module.so;
load_module modules/ngx_http_zstd_static_module.so;
```

Where the library is looked for
-------------------------------

The filter needs the Zstandard library and its header.  They are looked
for in this order:

1. `$ZSTD_INC` and `$ZSTD_LIB`, if you set them,
2. the compiler's own search path,
3. `/usr/local/include` and `/usr/local/lib`, which is where FreeBSD and
   the other ports-based systems put them.

The static archive is preferred over the shared library, because the
filter uses Zstandard functions that are only declared for static
linking.  Only the filter ends up linked against the library; the static
module does not need it and does not get it.

Directives
==========

ngx_http_zstd_filter_module
---------------------------

### zstd

**Syntax:** *zstd on | off;*
**Default:** *zstd off;*
**Context:** *http, server, location, if in location*

Enables or disables compressing the response.

### zstd_buffers

**Syntax:** *zstd_buffers number size;*
**Default:** *zstd_buffers 32 4k | 16 8k;*
**Context:** *http, server, location*

Number and size of the buffers used to compress a response.  The default
size is one memory page, so 4K or 8K depending on the platform.

### zstd_comp_level

**Syntax:** *zstd_comp_level level;*
**Default:** *zstd_comp_level 1;*
**Context:** *http, server, location*

Compression level, from 1 to `ZSTD_maxCLevel()`.

### zstd_dict_file

**Syntax:** *zstd_dict_file /path/to/dict;*
**Default:** *-*
**Context:** *http*

An external dictionary.

Be careful with this one.  The content coding says how to signal that
zstd is in use, and nothing about agreeing on a dictionary, so there is
no way for a client to find out which one you loaded.  Use it only where
both ends are yours and you can make them agree, for instance over a
header of your own.  See [upstream issue
2](https://github.com/tokers/zstd-nginx-module/issues/2).

### zstd_min_length

**Syntax:** *zstd_min_length length;*
**Default:** *zstd_min_length 20;*
**Context:** *http, server, location*

Responses shorter than this are not compressed.  The length is taken
from `Content-Length`, so a response without that header is always
compressed.

### zstd_types

**Syntax:** *zstd_types mime-type ...;*
**Default:** *zstd_types text/html;*
**Context:** *http, server, location*

MIME types to compress, in addition to `text/html`, which is always
included.  `*` matches everything.

ngx_http_zstd_static_module
---------------------------

### zstd_static

**Syntax:** *zstd_static on | off | always;*
**Default:** *zstd_static off;*
**Context:** *http, server, location*

Sends `file.zst` in place of `file` where one exists.  `gzip_vary` is
taken into account.

With `always` the `.zst` file is sent whatever the client announced,
which is only sensible where you know every client understands it.

Variables
=========

### $zstd_ratio

The ratio between the size of the response as it came in and as it went
out.  Empty where nothing was compressed.

Compatibility
=============

The test suite runs against nginx 1.28.3, 1.30.5 and 1.31.6, on Linux and
on FreeBSD.  Those are the last release of the previous stable line, the
current stable and the current mainline; nginx keeps nothing older alive.
Zstandard 1.4.0 and newer.

Test Suite
==========

The suite is written against
[Test::Nginx](https://metacpan.org/pod/Test::Nginx):

```
ci/build.sh 1.31.6 /tmp/nginx-test
TEST_NGINX_BINARY=/tmp/nginx-test/sbin/nginx prove -r t/
```

License
=======

BSD 2-Clause, see [LICENSE](LICENSE).
