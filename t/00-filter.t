use Test::Nginx::Socket 'no_plan';
use lib 'lib';

no_long_string();
log_level 'debug';
repeat_each(2);

run_tests();

__DATA__


=== TEST 1: zstd off
--- config
    location /test {
        zstd off;
        zstd_types text/plain;
        zstd_min_length 1;
        return 200 "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
        default_type text/plain;
    }
--- request
GET /test
--- more_headers
Accept-Encoding: zstd
--- response_headers
!Content-Encoding



=== TEST 2: the client did not ask for zstd
--- config
    location /test {
        zstd on;
        zstd_types text/plain;
        zstd_min_length 1;
        return 200 "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
        default_type text/plain;
    }
--- request
GET /test
--- response_headers
!Content-Encoding



=== TEST 3: the client asked for zstd
--- config
    location /test {
        zstd on;
        zstd_types text/plain;
        zstd_min_length 1;
        return 200 "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
        default_type text/plain;
    }
--- request
GET /test
--- more_headers
Accept-Encoding: zstd
--- response_headers
Content-Encoding: zstd



=== TEST 4: gzip is not zstd
--- config
    location /test {
        zstd on;
        zstd_types text/plain;
        zstd_min_length 1;
        return 200 "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
        default_type text/plain;
    }
--- request
GET /test
--- more_headers
Accept-Encoding: gzip, deflate
--- response_headers
!Content-Encoding



=== TEST 5: shorter than zstd_min_length
--- config
    location /test {
        zstd on;
        zstd_types text/plain;
        zstd_min_length 1000;
        return 200 "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
        default_type text/plain;
    }
--- request
GET /test
--- more_headers
Accept-Encoding: zstd
--- response_headers
!Content-Encoding



=== TEST 6: a type that is not listed
--- config
    location /test {
        zstd on;
        zstd_types text/css;
        zstd_min_length 1;
        return 200 "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
        default_type text/plain;
    }
--- request
GET /test
--- more_headers
Accept-Encoding: zstd
--- response_headers
!Content-Encoding



=== TEST 7: text/html is compressed without being listed
--- config
    location /test {
        zstd on;
        zstd_types text/css;
        zstd_min_length 1;
        return 200 "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
        default_type text/html;
    }
--- request
GET /test
--- more_headers
Accept-Encoding: zstd
--- response_headers
Content-Encoding: zstd



=== TEST 8: the asterisk matches every type
--- config
    location /test {
        zstd on;
        zstd_types *;
        zstd_min_length 1;
        return 200 "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
        default_type application/octet-stream;
    }
--- request
GET /test
--- more_headers
Accept-Encoding: zstd
--- response_headers
Content-Encoding: zstd



=== TEST 9: a file from disk is compressed
--- config
    location /test {
        zstd on;
        zstd_types application/octet-stream;
        zstd_min_length 1;
        default_type application/octet-stream;
        root ../../t/suite;
    }
--- request
GET /test
--- more_headers
Accept-Encoding: zstd
--- response_headers
Content-Encoding: zstd



=== TEST 10: a small buffer still produces one frame
--- config
    location /test {
        zstd on;
        zstd_types application/octet-stream;
        zstd_min_length 1;
        zstd_buffers 2 1k;
        default_type application/octet-stream;
        root ../../t/suite;
    }
--- request
GET /test
--- more_headers
Accept-Encoding: zstd
--- response_headers
Content-Encoding: zstd



=== TEST 11: a single large output buffer ends the frame only when the input is done
--- config
    location /test {
        zstd on;
        zstd_types application/octet-stream;
        zstd_min_length 1;
        output_buffers 1 512k;
        default_type application/octet-stream;
        root ../../t/suite;
    }
--- request
GET /test
--- more_headers
Accept-Encoding: zstd
--- response_headers
Content-Encoding: zstd
--- no_error_log
[error]
