#!/bin/bash
#
# Copyright 2012 Google Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# Author: jefftk@google.com (Jeff Kaufman)
#
#
# Runs pagespeed's generic system test.  Will eventually run nginx-specific
# tests as well.
#
# Exits with status 0 if all tests pass.
# Exits with status 1 immediately if any test fails.
# Exits with status 2 if command line args are wrong.
#
# Usage:
#   ./ngx_system_test.sh primary_port secondary_port mod_pagespeed_dir
# Example:
#   ./ngx_system_test.sh 8050 8051 /path/to/mod_pagespeed
#

# To run this test with valgrind, set the environment variable USE_VALGRIND to
# true.
USE_VALGRIND=${USE_VALGRIND:-false}

if [ "$#" -ne 4 ] ; then
  echo "Usage: $0 primary_port secondary_port mod_pagespeed_dir"
  echo "  nginx_executable"
  exit 2
fi

PRIMARY_PORT="$1"
SECONDARY_PORT="$2"
MOD_PAGESPEED_DIR="$3"
NGINX_EXECUTABLE="$4"

PRIMARY_HOSTNAME="localhost:$PRIMARY_PORT"
SECONDARY_HOSTNAME="localhost:$SECONDARY_PORT"

SERVER_ROOT="$MOD_PAGESPEED_DIR/src/install/"

# We need check and check_not before we source SYSTEM_TEST_FILE that provides
# them.
function handle_failure_simple() {
  echo "FAIL"
  exit 1
}
function check_simple() {
  echo "     check" "$@"
  "$@" || handle_failure_simple
}
function check_not_simple() {
  echo "     check_not" "$@"
  "$@" && handle_failure_simple
}

this_dir="$( cd $(dirname "$0") && pwd)"

# stop nginx
killall nginx

TEST_TMP="$this_dir/tmp"
rm -r "$TEST_TMP"
check_simple mkdir "$TEST_TMP"
FILE_CACHE="$TEST_TMP/file-cache/"
check_simple mkdir "$FILE_CACHE"
SECONDARY_CACHE="$TEST_TMP/file-cache/secondary/"
check_simple mkdir "$SECONDARY_CACHE"

VALGRIND_OPTIONS=""

if $USE_VALGRIND; then
  DAEMON=off
  MASTER_PROCESS=off
else
  DAEMON=on
  MASTER_PROCESS=on
fi

# set up the config file for the test
PAGESPEED_CONF="$TEST_TMP/pagespeed_test.conf"
PAGESPEED_CONF_TEMPLATE="$this_dir/pagespeed_test.conf.template"
# check for config file template
check_simple test -e "$PAGESPEED_CONF_TEMPLATE"
# create PAGESPEED_CONF by substituting on PAGESPEED_CONF_TEMPLATE
echo > $PAGESPEED_CONF <<EOF
This file is automatically generated from $PAGESPEED_CONF_TEMPLATE"
by nginx_system_test.sh; don't edit here."
EOF
cat $PAGESPEED_CONF_TEMPLATE \
  | sed 's#@@DAEMON@@#'"$DAEMON"'#' \
  | sed 's#@@MASTER_PROCESS@@#'"$MASTER_PROCESS"'#' \
  | sed 's#@@TEST_TMP@@#'"$TEST_TMP/"'#' \
  | sed 's#@@FILE_CACHE@@#'"$FILE_CACHE/"'#' \
  | sed 's#@@SECONDARY_CACHE@@#'"$SECONDARY_CACHE/"'#' \
  | sed 's#@@SERVER_ROOT@@#'"$SERVER_ROOT"'#' \
  | sed 's#@@PRIMARY_PORT@@#'"$PRIMARY_PORT"'#' \
  | sed 's#@@SECONDARY_PORT@@#'"$SECONDARY_PORT"'#' \
  >> $PAGESPEED_CONF
# make sure we substituted all the variables
check_not_simple grep @@ $PAGESPEED_CONF

# start nginx with new config
if $USE_VALGRIND; then
  echo "Run this command in another terminal and then press enter:"
  echo "  valgrind $NGINX_EXECUTABLE -c $PAGESPEED_CONF"
  read
else
  check_simple "$NGINX_EXECUTABLE" -c "$PAGESPEED_CONF"
fi

# run generic system tests
SYSTEM_TEST_FILE="$MOD_PAGESPEED_DIR/src/install/system_test.sh"

if [ ! -e "$SYSTEM_TEST_FILE" ] ; then
  echo "Not finding $SYSTEM_TEST_FILE -- is mod_pagespeed not in a parallel"
  echo "directory to ngx_pagespeed?"
  exit 2
fi

PSA_JS_LIBRARY_URL_PREFIX="ngx_pagespeed_static"

PAGESPEED_EXPECTED_FAILURES="
  ~compression is enabled for rewritten JS.~
  ~convert_meta_tags~
  ~insert_dns_prefetch~
  ~In-place resource optimization~
"

# The existing system test takes its arguments as positional parameters, and
# wants different ones than we want, so we need to reset our positional args.
set -- "$PRIMARY_HOSTNAME"
source $SYSTEM_TEST_FILE

# nginx-specific system tests

start_test Check for correct default X-Page-Speed header format.
OUT=$($WGET_DUMP $EXAMPLE_ROOT/combine_css.html)
check_from "$OUT" egrep -q \
  '^X-Page-Speed: [0-9]+[.][0-9]+[.][0-9]+[.][0-9]+-[0-9]+'

start_test pagespeed is defaulting to more than PassThrough
fetch_until $TEST_ROOT/bot_test.html 'grep -c \.pagespeed\.' 2

# Test that loopback route fetcher works with vhosts not listening on
# 127.0.0.1
start_test IP choice for loopback fetches.
HOST_NAME="loopbackfetch.example.com"
URL="$HOST_NAME/mod_pagespeed_example/rewrite_images.html"
http_proxy=127.0.0.2:$SECONDARY_PORT \
    fetch_until $URL 'grep -c .pagespeed.ic' 2

# When we allow ourself to fetch a resource because the Host header tells us
# that it is one of our resources, we should be fetching it from ourself.
start_test "Loopback fetches go to local IPs without DNS lookup"

# If we're properly fetching from ourself we will issue loopback fetches for
# /mod_pagespeed_example/combine_javascriptN.js, which will succeed, so
# combining will work.  If we're taking 'Host:www.google.com' to mean that we
# should fetch from www.google.com then those fetches will fail because
# google.com won't have /mod_pagespeed_example/combine_javascriptN.js and so
# we'll not rewrite any resources.

URL="$HOSTNAME/mod_pagespeed_example/combine_javascript.html"
URL+="?ModPagespeed=on&ModPagespeedFilters=combine_javascript"
fetch_until "$URL" "fgrep -c .pagespeed." 1 --header=Host:www.google.com

# If this accepts the Host header and fetches from google.com it will fail with
# a 404.  Instead it should use a loopback fetch and succeed.
URL="$HOSTNAME/mod_pagespeed_example/.pagespeed.ce.8CfGBvwDhH.css"
check wget -O /dev/null --header=Host:www.google.com "$URL"

test_filter combine_css combines 4 CSS files into 1.
fetch_until $URL 'grep -c text/css' 1
check run_wget_with_args $URL
test_resource_ext_corruption $URL $combine_css_filename

test_filter extend_cache rewrites an image tag.
fetch_until $URL 'grep -c src.*91_WewrLtP' 1
check run_wget_with_args $URL
echo about to test resource ext corruption...
test_resource_ext_corruption $URL images/Puzzle.jpg.pagespeed.ce.91_WewrLtP.jpg

test_filter outline_javascript outlines large scripts, but not small ones.
check run_wget_with_args $URL
check egrep -q '<script.*large.*src=' $FETCHED       # outlined
check egrep -q '<script.*small.*var hello' $FETCHED  # not outlined
start_test compression is enabled for rewritten JS.
JS_URL=$(egrep -o http://.*[.]pagespeed.*[.]js $FETCHED)
echo "JS_URL=\$\(egrep -o http://.*[.]pagespeed.*[.]js $FETCHED\)=\"$JS_URL\""
JS_HEADERS=$($WGET -O /dev/null -q -S --header='Accept-Encoding: gzip' \
  $JS_URL 2>&1)
echo JS_HEADERS=$JS_HEADERS
check_from "$JS_HEADERS" egrep -qi 'HTTP/1[.]. 200 OK'
check_from "$JS_HEADERS" fgrep -qi 'Content-Encoding: gzip'
check_from "$JS_HEADERS" fgrep -qi 'Vary: Accept-Encoding'
check_from "$JS_HEADERS" egrep -qi '(Etag: W/"0")|(Etag: W/"0-gzip")'
check_from "$JS_HEADERS" fgrep -qi 'Last-Modified:'

WGET_ARGS="" # Done with test_filter, so clear WGET_ARGS.

start_test Respect X-Forwarded-Proto when told to
FETCHED=$OUTDIR/x_forwarded_proto
URL=$SECONDARY_HOSTNAME/mod_pagespeed_example/?ModPagespeedFilters=add_base_tag
HEADERS="--header=X-Forwarded-Proto:https --header=Host:xfp.example.com"
check $WGET_DUMP -O $FETCHED $HEADERS $URL
# When enabled, we respect X-Forwarded-Proto and thus list base as https.
check fgrep -q '<base href="https://' $FETCHED

# Several cache flushing tests.

start_test Touching cache.flush flushes the cache.

# If we write fixed values into the css file here, there is a risk that
# we will end up seeing the 'right' value because an old process hasn't
# invalidated things yet, rather than because it updated to what we expect
# in the first run followed by what we expect in the second run.
# So, we incorporate the timestamp into RGB colors, using hours
# prefixed with 1 (as 0-123 fits the 0-255 range) to get a second value.
# A one-second precision is good enough since there is a sleep 2 below.
COLOR_SUFFIX=`date +%H,%M,%S\)`
COLOR0=rgb\($COLOR_SUFFIX
COLOR1=rgb\(1$COLOR_SUFFIX

# We test on three different cache setups:
#
#   1. A virtual host using the normal FileCachePath.
#   2. Another virtual host with a different FileCachePath.
#   3. Another virtual host with a different CacheFlushFilename.
#
# This means we need to repeat many of the steps three times.

echo "Clear out our existing state before we begin the test."
check touch "$FILE_CACHE/cache.flush"
check touch "$FILE_CACHE/othercache.flush"
check touch "$SECONDARY_CACHE/cache.flush"
sleep 1

CSS_FILE="$SERVER_ROOT/mod_pagespeed_test/update.css"
echo ".class myclass { color: $COLOR0; }" > "$CSS_FILE"

URL_PATH="mod_pagespeed_test/cache_flush_test.html"

URL="$SECONDARY_HOSTNAME/$URL_PATH"
CACHE_A="--header=Host:cache_a.example.com"
fetch_until $URL "grep -c $COLOR0" 1 $CACHE_A

CACHE_B="--header=Host:cache_b.example.com"
fetch_until $URL "grep -c $COLOR0" 1 $CACHE_B

CACHE_C="--header=Host:cache_c.example.com"
fetch_until $URL "grep -c $COLOR0" 1 $CACHE_C

# All three caches are now populated.

# TODO(jefftk): Check statistics here.  In apache_system_test.sh we can track
# reported flushed by looking at statistics, but this isn't ported to nginx
# yet.  Once that is ported, come back here and make sure it's correct.

# Now change the file to $COLOR1.
echo ".class myclass { color: $COLOR1; }" > "$CSS_FILE"

# We expect to have a stale cache for 5 minutes, so the result should stay
# $COLOR0.  This only works because we have only one worker process.  If we had
# more than one then the worker process handling this request might be different
# than the one that got the previous one, and it wouldn't be in cache.
OUT="$($WGET_DUMP $CACHE_A "$URL")"
check_from "$OUT" fgrep $COLOR0

OUT="$($WGET_DUMP $CACHE_B "$URL")"
check_from "$OUT" fgrep $COLOR0

OUT="$($WGET_DUMP $CACHE_C "$URL")"
check_from "$OUT" fgrep $COLOR0

# Flush the cache by touching a special file in the cache directory.  Now
# css gets re-read and we get $COLOR1 in the output.  Sleep here to avoid
# a race due to 1-second granularity of file-system timestamp checks.  For
# the test to pass we need to see time pass from the previous 'touch'.
#
# The three vhosts here all have CacheFlushPollIntervalSec set to 1.

sleep 2
check touch "$FILE_CACHE/cache.flush"
sleep 1

# Check that CACHE_A flushed properly.
fetch_until $URL "grep -c $COLOR1" 1 $CACHE_A

start_test Flushing one cache does not flush all caches.

# Check that CACHE_B and CACHE_C are still serving a stale version.
OUT="$($WGET_DUMP $CACHE_B "$URL")"
check_from "$OUT" fgrep $COLOR0

OUT="$($WGET_DUMP $CACHE_C "$URL")"
check_from "$OUT" fgrep $COLOR0

start_test Secondary caches also flush.

# Now flush the other two files so they can see the color change.
check touch "$FILE_CACHE/othercache.flush"
check touch "$SECONDARY_CACHE/cache.flush"
sleep 1

# Check that CACHE_B and C flushed properly.
fetch_until $URL "grep -c $COLOR1" 1 $CACHE_B
fetch_until $URL "grep -c $COLOR1" 1 $CACHE_C

# Clean up update.css from mod_pagespeed_test so it doesn't leave behind
# a stray file not under source control.
rm -f $CSS_FILE

# Test RetainComment directive.
test_filter remove_comments retains appropriate comments.
URL="$SECONDARY_HOSTNAME/mod_pagespeed_example/$FILE"
check run_wget_with_args $URL --header=Host:retaincomment.example.com
check grep -q retained $FETCHED        # RetainComment directive

# Make sure that when in PreserveURLs mode that we don't rewrite URLs. This is
# non-exhaustive, the unit tests should cover the rest.
# Note: We block with psatest here because this is a negative test.  We wouldn't
# otherwise know how many wget attempts should be made.
WGET_ARGS="--header=X-PSA-Blocking-Rewrite:psatest"
WGET_ARGS+=" --header=Host:preserveurls.example.com"

start_test PreserveURLs on prevents URL rewriting
FILE=preserveurls/on/preserveurls.html
URL=$SECONDARY_HOSTNAME/mod_pagespeed_test/$FILE
FETCHED=$OUTDIR/preserveurls.html
check run_wget_with_args $URL
WGET_ARGS=""
check_not fgrep -q .pagespeed. $FETCHED

# When PreserveURLs is off do a quick check to make sure that normal rewriting
# occurs.  This is not exhaustive, the unit tests should cover the rest.
start_test PreserveURLs off causes URL rewriting
WGET_ARGS="--header=Host:preserveurls.example.com"
FILE=preserveurls/off/preserveurls.html
URL=$SECONDARY_HOSTNAME/mod_pagespeed_test/$FILE
FETCHED=$OUTDIR/preserveurls.html
# Check that style.css was inlined.
fetch_until $URL 'egrep -c big.css.pagespeed.' 1
# Check that introspection.js was inlined.
fetch_until $URL 'grep -c document\.write(\"External' 1
# Check that the image was optimized.
fetch_until $URL 'grep -c BikeCrashIcn\.png\.pagespeed\.' 2

# When Cache-Control: no-transform is in the response make sure that
# the URL is not rewritten and that the no-transform header remains
# in the resource.
start_test HonorNoTransform cache-control: no-transform
WGET_ARGS="--header=X-PSA-Blocking-Rewrite:psatest"
WGET_ARGS+=" --header=Host:notransform.example.com"
URL="$SECONDARY_HOSTNAME/mod_pagespeed_test/no_transform/image.html"
FETCHED=$OUTDIR/output
wget -O - $URL $WGET_ARGS > $FETCHED
sleep .1  # Give pagespeed time to transform the image if it's going to.
wget -O - $URL $WGET_ARGS > $FETCHED
# Make sure that the URLs in the html are not rewritten
check_not fgrep -q '.pagespeed.' $FETCHED
URL="$SECONDARY_HOSTNAME/mod_pagespeed_test/no_transform/BikeCrashIcn.png"
wget -O - -S $URL $WGET_ARGS &> $FETCHED
# Make sure that the no-transfrom header is still there
check grep -q 'Cache-Control:.*no-transform' $FETCHED
WGET_ARGS=""

test_filter rewrite_images inlines, compresses, and resizes.
fetch_until $URL 'grep -c data:image/png' 1  # inlined
fetch_until $URL 'grep -c .pagespeed.ic' 2   # two images optimized

# Verify with a blocking fetch that pagespeed_no_transform worked and was
# stripped.
fetch_until $URL 'grep -c "images/disclosure_open_plus.png"' 1 \
  '--header=X-PSA-Blocking-Rewrite:psatest'
fetch_until $URL 'grep -c "pagespeed_no_transform"' 0 \
  '--header=X-PSA-Blocking-Rewrite:psatest'

check run_wget_with_args $URL
check_file_size "$OUTDIR/xBikeCrashIcn*" -lt 25000     # re-encoded
check_file_size "$OUTDIR/*256x192*Puzzle*" -lt 24126   # resized
URL=$EXAMPLE_ROOT"/rewrite_images.html?ModPagespeedFilters=rewrite_images"
IMG_URL=$(egrep -o http://.*.pagespeed.*.jpg $FETCHED | head -n1)
check [ x"$IMG_URL" != x ]
start_test headers for rewritten image
echo IMG_URL="$IMG_URL"
IMG_HEADERS=$($WGET -O /dev/null -q -S --header='Accept-Encoding: gzip' \
  $IMG_URL 2>&1)
echo "IMG_HEADERS=\"$IMG_HEADERS\""
check_from "$IMG_HEADERS" egrep -qi 'HTTP/1[.]. 200 OK'
# Make sure we have some valid headers.
check_from "$IMG_HEADERS" fgrep -qi 'Content-Type: image/jpeg'
# Make sure the response was not gzipped.
start_test Images are not gzipped.
check_not_from "$IMG_HEADERS" fgrep -i 'Content-Encoding: gzip'
# Make sure there is no vary-encoding
start_test Vary is not set for images.
check_not_from "$IMG_HEADERS" fgrep -i 'Vary: Accept-Encoding'
# Make sure there is an etag
start_test Etags is present.
check_from "$IMG_HEADERS" fgrep -qi 'Etag: W/"0"'
# Make sure an extra header is propagated from input resource to output
# resource.  X-Extra-Header is added in pagespeed_test.conf.template
start_test Extra header is present
check_from "$IMG_HEADERS" fgrep -qi 'X-Extra-Header'
# Make sure there is a last-modified tag
start_test Last-modified is present.
check_from "$IMG_HEADERS" fgrep -qi 'Last-Modified'

IMAGES_QUALITY="ModPagespeedImageRecompressionQuality"
JPEG_QUALITY="ModPagespeedJpegRecompressionQuality"
WEBP_QUALITY="ModPagespeedImageWebpRecompressionQuality"
start_test quality of jpeg output images with generic quality flag
IMG_REWRITE=$TEST_ROOT"/image_rewriting/rewrite_images.html"
REWRITE_URL=$IMG_REWRITE"?ModPagespeedFilters=rewrite_images"
URL=$REWRITE_URL"&"$IMAGES_QUALITY"=75"
fetch_until -save -recursive $URL 'grep -c .pagespeed.ic' 2 # 2 images optimized
# This filter produces different images on 32 vs 64 bit builds. On 32 bit, the
# size is 8157B, while on 64 it is 8155B. Initial investigation showed no
# visible differences between the generated images.
# TODO(jmaessen) Verify that this behavior is expected.
#
# Note that if this test fails with 8251 it means that you have managed to get
# progressive jpeg conversion turned on in this testcase, which makes the output
# larger.  The threshold factor kJpegPixelToByteRatio in image_rewrite_filter.cc
# is tuned to avoid that.
check_file_size "$OUTDIR/*256x192*Puzzle*" -le 8157   # resized

IMAGES_QUALITY="ModPagespeedImageRecompressionQuality"
JPEG_QUALITY="ModPagespeedJpegRecompressionQuality"
WEBP_QUALITY="ModPagespeedImageWebpRecompressionQuality"

start_test quality of jpeg output images
IMG_REWRITE=$TEST_ROOT"/jpeg_rewriting/rewrite_images.html"
REWRITE_URL=$IMG_REWRITE"?ModPagespeedFilters=rewrite_images"
URL=$REWRITE_URL",recompress_jpeg&"$IMAGES_QUALITY"=85&"$JPEG_QUALITY"=70"
fetch_until -save -recursive $URL 'grep -c .pagespeed.ic' 2 # 2 images optimized
#
# If this this test fails because the image size is 7673 bytes it means
# that image_rewrite_filter.cc decided it was a good idea to convert to
# progressive jpeg, and in this case it's not.  See the not above on
# kJpegPixelToByteRatio.
check_file_size "$OUTDIR/*256x192*Puzzle*" -le 7564   # resized

start_test quality of webp output images
rm -rf $OUTDIR
mkdir $OUTDIR
IMG_REWRITE=$TEST_ROOT"/webp_rewriting/rewrite_images.html"
REWRITE_URL=$IMG_REWRITE"?ModPagespeedFilters=rewrite_images"
URL=$REWRITE_URL",convert_jpeg_to_webp&"$IMAGES_QUALITY"=75&"$WEBP_QUALITY"=65"
check run_wget_with_args --header 'X-PSA-Blocking-Rewrite: psatest' $URL
check_file_size "$OUTDIR/*webp*" -le 1784   # resized, optimized to webp

start_test respect vary user-agent
WGET_ARGS=""
URL="$SECONDARY_HOSTNAME/mod_pagespeed_test/vary/index.html"
URL+="?ModPagespeedFilters=inline_css"
FETCH_CMD="$WGET_DUMP --header=Host:respectvary.example.com $URL"
OUT=$($FETCH_CMD)
# We want to verify that css is not inlined, but if we just check once then
# pagespeed doesn't have long enough to be able to inline it.
sleep .1
OUT=$($FETCH_CMD)
check_not_from "$OUT" fgrep "<style>"

WGET_ARGS=""
start_test ModPagespeedShardDomain directive in location block
fetch_until -save $TEST_ROOT/shard/shard.html 'grep -c \.pagespeed\.' 4
check [ $(grep -ce href=\"http://shard1 $FETCH_FILE) = 2 ];
check [ $(grep -ce href=\"http://shard2 $FETCH_FILE) = 2 ];

start_test ModPagespeedLoadFromFile
URL=$TEST_ROOT/load_from_file/index.html?ModPagespeedFilters=inline_css
fetch_until $URL 'grep -c blue' 1

# The "httponly" directory is disallowed.
fetch_until $URL 'fgrep -c web.httponly.example.css' 1

# Loading .ssp.css files from file is disallowed.
fetch_until $URL 'fgrep -c web.example.ssp.css' 1

# There's an exception "allow" rule for "exception.ssp.css" so it can be loaded
# directly from the filesystem.
fetch_until $URL 'fgrep -c file.exception.ssp.css' 1

start_test ModPagespeedLoadFromFileMatch
URL=$TEST_ROOT/load_from_file_match/index.html?ModPagespeedFilters=inline_css
fetch_until $URL 'grep -c blue' 1

start_test Custom headers remain on HTML, but cache should be disabled.
URL=$TEST_ROOT/rewrite_compressed_js.html
echo $WGET_DUMP $URL
HTML_HEADERS=$($WGET_DUMP $URL)
check_from "$HTML_HEADERS" egrep -q "X-Extra-Header: 1"
# The extra header should only be added once, not twice.
check_not_from "$HTML_HEADERS" egrep -q "X-Extra-Header: 1, 1"
check_from "$HTML_HEADERS" egrep -q 'Cache-Control: max-age=0, no-cache'

start_test ModPagespeedModifyCachingHeaders
URL=$TEST_ROOT/retain_cache_control/index.html
OUT=$($WGET_DUMP $URL)
check_from "$OUT" grep -q "Cache-Control: private, max-age=3000"
check_from "$OUT" grep -q "Last-Modified:"

test_filter combine_javascript combines 2 JS files into 1.
start_test combine_javascript with long URL still works
URL=$TEST_ROOT/combine_js_very_many.html?ModPagespeedFilters=combine_javascript
fetch_until $URL 'grep -c src=' 4

start_test aris disables js combining for introspective js and only i-js
URL="$TEST_ROOT/avoid_renaming_introspective_javascript__on/"
URL+="?ModPagespeedFilters=combine_javascript"
fetch_until $URL 'grep -c src=' 2

start_test aris disables js combining only when enabled
URL="$TEST_ROOT/avoid_renaming_introspective_javascript__off.html?"
URL+="ModPagespeedFilters=combine_javascript"
fetch_until $URL 'grep -c src=' 1

test_filter inline_javascript inlines a small JS file
start_test aris disables js inlining for introspective js and only i-js
URL="$TEST_ROOT/avoid_renaming_introspective_javascript__on/"
URL+="?ModPagespeedFilters=inline_javascript"
fetch_until $URL 'grep -c src=' 1

start_test aris disables js inlining only when enabled
URL="$TEST_ROOT/avoid_renaming_introspective_javascript__off.html"
URL+="?ModPagespeedFilters=inline_javascript"
fetch_until $URL 'grep -c src=' 0

test_filter rewrite_javascript minifies JavaScript and saves bytes.
start_test aris disables js cache extention for introspective js and only i-js
URL="$TEST_ROOT/avoid_renaming_introspective_javascript__on/"
URL+="?ModPagespeedFilters=rewrite_javascript"
# first check something that should get rewritten to know we're done with
# rewriting
fetch_until -save $URL 'grep -c "src=\"../normal.js\""' 0
check [ $(grep -c "src=\"../introspection.js\"" $FETCH_FILE) = 1 ]

start_test aris disables js cache extension only when enabled
URL="$TEST_ROOT/avoid_renaming_introspective_javascript__off.html"
URL+="?ModPagespeedFilters=rewrite_javascript"
fetch_until -save $URL 'grep -c src=\"normal.js\"' 0
check [ $(grep -c src=\"introspection.js\" $FETCH_FILE) = 0 ]

# Check that no filter changes urls for introspective javascript if
# avoid_renaming_introspective_javascript is on
start_test aris disables url modification for introspective js
URL="$TEST_ROOT/avoid_renaming_introspective_javascript__on/"
URL+="?ModPagespeedFilters=testing,core"
# first check something that should get rewritten to know we're done with
# rewriting
fetch_until -save $URL 'grep -c src=\"../normal.js\"' 0
check [ $(grep -c src=\"../introspection.js\" $FETCH_FILE) = 1 ]

start_test aris disables url modification only when enabled
URL="$TEST_ROOT/avoid_renaming_introspective_javascript__off.html"
URL+="?ModPagespeedFilters=testing,core"
fetch_until -save $URL 'grep -c src=\"normal.js\"' 0
check [ $(grep -c src=\"introspection.js\" $FETCH_FILE) = 0 ]

start_test HTML add_instrumentation lacks '&amp;' and does not contain CDATA
$WGET -O $WGET_OUTPUT $TEST_ROOT/add_instrumentation.html\
?ModPagespeedFilters=add_instrumentation
check [ $(grep -c "\&amp;" $WGET_OUTPUT) = 0 ]
# In mod_pagespeed this check is that we *do* contain CDATA.  That's because
# mod_pagespeed generally runs before response headers are finalized so it has
# to assume the page is xhtml because the 'Content-Type' header might just not
# have been set yet.  See RewriteDriver::MimeTypeXhtmlStatus().  In
# ngx_pagespeed response headers are already final when we're processing the
# body, so we know whether we're dealing with xhtml and in this case know we
# don't need CDATA.
check [ $(grep -c '//<\!\[CDATA\[' $WGET_OUTPUT) = 0 ]

start_test XHTML add_instrumentation also lacks '&amp;' but contains CDATA
$WGET -O $WGET_OUTPUT $TEST_ROOT/add_instrumentation.xhtml\
?ModPagespeedFilters=add_instrumentation
check [ $(grep -c "\&amp;" $WGET_OUTPUT) = 0 ]
check [ $(grep -c '//<\!\[CDATA\[' $WGET_OUTPUT) = 1 ]

start_test cache_partial_html enabled has no effect
$WGET -O $WGET_OUTPUT $TEST_ROOT/add_instrumentation.html\
?ModPagespeedFilters=cache_partial_html
check [ $(grep -c '<html>' $WGET_OUTPUT) = 1 ]
check [ $(grep -c '<body>' $WGET_OUTPUT) = 1 ]
check [ $(grep -c 'pagespeed.panelLoader' $WGET_OUTPUT) = 0 ]

start_test flush_subresources rewriter is not applied
URL="$TEST_ROOT/flush_subresources.html?\
ModPagespeedFilters=flush_subresources,extend_cache_css,\
extend_cache_scripts"
# Fetch once with X-PSA-Blocking-Rewrite so that the resources get rewritten and
# property cache (once it's ported to ngx_pagespeed) is updated with them.
wget -O - --header 'X-PSA-Blocking-Rewrite: psatest' $URL > $TEMPDIR/flush.$$
# Fetch again. The property cache has (would have, if it were ported) the
# subresources this time but flush_subresources rewriter is not applied. This is
# a negative test case because this rewriter does not exist in ngx_pagespeed
# yet.
check [ `wget -O - $URL | grep -o 'link rel="subresource"' | wc -l` = 0 ]
rm -f $TEMPDIR/flush.$$

WGET_ARGS=""
start_test Respect custom options on resources.
IMG_NON_CUSTOM="$EXAMPLE_ROOT/images/xPuzzle.jpg.pagespeed.ic.fakehash.jpg"
IMG_CUSTOM="$TEST_ROOT/custom_options/xPuzzle.jpg.pagespeed.ic.fakehash.jpg"

# Identical images, but in the location block for the custom_options directory
# we additionally disable core-filter convert_jpeg_to_progressive which gives a
# larger file.
fetch_until $IMG_NON_CUSTOM 'wc -c' 216942
fetch_until $IMG_CUSTOM 'wc -c' 231192

# Test our handling of headers when a FLUSH event occurs.
# Always fetch the first file so we can check if PHP is enabled.
start_test Headers are not destroyed by a flush event.
FILE=php_withoutflush.php
URL=$TEST_ROOT/$FILE
FETCHED=$OUTDIR/$FILE
$WGET_DUMP $URL > $FETCHED
check_not grep -q '<?php' $FETCHED

check [ $(grep -c '^X-Page-Speed:'               $FETCHED) = 1 ]
check [ $(grep -c '^X-My-PHP-Header: without_flush' $FETCHED) = 1 ]

# mod_pagespeed doesn't clear the content length header if there aren't any
# flushes, but ngx_pagespeed does.  It's possible that ngx_pagespeed should also
# avoid clearing the content length, but it doesn't and I don't think it's
# important, so don't check for content-length.
# check [ $(grep -c '^Content-Length: [0-9]'          $FETCHED) = 1 ]

FILE=php_withflush.php
URL=$TEST_ROOT/$FILE
FETCHED=$OUTDIR/$FILE
$WGET_DUMP $URL > $FETCHED
check [ $(grep -c '^X-Page-Speed:'               $FETCHED) = 1 ]
check [ $(grep -c '^X-My-PHP-Header: with_flush'    $FETCHED) = 1 ]

# Test fetching a pagespeed URL via Nginx running as a reverse proxy, with
# pagespeed loaded, but disabled for the proxied domain. As reported in
# Issue 582 this used to fail in mod_pagespeed with a 403 (Forbidden).
start_test Reverse proxy a pagespeed URL.

PROXY_PATH="http://modpagespeed.com/styles"
ORIGINAL="${PROXY_PATH}/yellow.css"
FILTERED="${PROXY_PATH}/A.yellow.css.pagespeed.cf.KM5K8SbHQL.css"
WGET_ARGS="--save-headers"

# We should be able to fetch the original ...
echo  http_proxy=$SECONDARY_HOSTNAME $WGET --save-headers -O - $ORIGINAL
OUT=$(http_proxy=$SECONDARY_HOSTNAME $WGET --save-headers -O - $ORIGINAL 2>&1)
check_from "$OUT" fgrep " 200 OK"
# ... AND the rewritten version.
echo  http_proxy=$SECONDARY_HOSTNAME $WGET --save-headers -O - $FILTERED
OUT=$(http_proxy=$SECONDARY_HOSTNAME $WGET --save-headers -O - $FILTERED 2>&1)
check_from "$OUT" fgrep " 200 OK"

start_test MapProxyDomain
# depends on MapProxyDomain in pagespeed_test.conf.template
URL=$EXAMPLE_ROOT/proxy_external_resource.html
echo Rewrite HTML with reference to a proxyable image.
fetch_until -save -recursive $URL \
    'grep -c pss_images/xPuzzle\.jpg\.pagespeed\.ic' 1
check_file_size "$OUTDIR/xPuzzle*" -lt 60000

# To make sure that we can reconstruct the proxied content by going back
# to the origin, we must avoid hitting the output cache.
# Note that cache-flushing does not affect the cache of rewritten resources;
# only input-resources and metadata.  To avoid hitting that cache and force
# us to rewrite the resource from origin, we grab this resource from a
# virtual host attached to a different cache.
#
# With the proper hash, we'll get a long cache lifetime.
SECONDARY_HOST="http://mpd.example.com/pss_images"
PROXIED_IMAGE="$SECONDARY_HOST/$(basename $OUTDIR/xPuzzle*)"
WGET_ARGS="--save-headers"

echo $PROXIED_IMAGE expecting one year cache.
http_proxy=$SECONDARY_HOSTNAME fetch_until $PROXIED_IMAGE \
    "grep -c max-age=31536000" 1

# With the wrong hash, we'll get a short cache lifetime (and also no output
# cache hit.
WRONG_HASH="0"
PROXIED_IMAGE="$SECONDARY_HOST/xPuzzle.jpg.pagespeed.ic.$WRONG_HASH.jpg"
echo Fetching $PROXIED_IMAGE expecting short private cache.
http_proxy=$SECONDARY_HOSTNAME fetch_until $PROXIED_IMAGE \
    "grep -c max-age=300,private" 1

WGET_ARGS=""

# This is dependent upon having a /ngx_pagespeed_beacon handler.
test_filter add_instrumentation beacons load.

# Nginx won't sent a Content-Length header on a 204, and while this is correct
# per rfc 2616 wget hangs.  So set wget to time out after one second,
# "--timeout=1", and try only once, "-t 1", and check that we got a 204.
OUT=$(wget -q  --save-headers -O - -t 1 --timeout=1 \
      http://$HOSTNAME/ngx_pagespeed_beacon?ets=load:13)
check_from "$OUT" grep '^HTTP/1.1 204'

start_test server-side includes
fetch_until -save $TEST_ROOT/ssi/ssi.shtml?ModPagespeedFilters=combine_css \
    'grep -c \.pagespeed\.' 1
check [ $(grep -ce $combine_css_filename $FETCH_FILE) = 1 ];

check_failures_and_exit
