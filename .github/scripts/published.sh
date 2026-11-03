#!/bin/sh
# Asks a registry whether a version is already there, so a tag run can be
# repeated (or follow a manual publish) without failing on a duplicate.
#   published.sh <label> <url>
# The URL must answer 200 when the version exists and 404 when it does not;
# any other answer stops the job rather than guessing. Writes published=true or
# published=false to $GITHUB_OUTPUT.
set -eu
label=$1
url=$2
code=$(curl -s -o /dev/null -w '%{http_code}' -A 'alpr-sh/sdk release workflow' "$url")
case "$code" in
200)
	echo "::notice::$label already has this version; nothing to publish."
	echo "published=true" >>"$GITHUB_OUTPUT"
	;;
404)
	echo "published=false" >>"$GITHUB_OUTPUT"
	;;
*)
	echo "::error::$label answered HTTP $code for $url"
	exit 1
	;;
esac
