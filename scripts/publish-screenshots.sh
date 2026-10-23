#!/bin/bash
# Replaces the `screenshots` branch with the latest PNGs so they can be viewed on GitHub, even from a phone.
set -euo pipefail

src="$PWD/ci-results"
work=$(mktemp -d)
cp "$src"/*.png "$work"/
cd "$work"
{
  echo "# 画面のスクリーンショット"
  echo
  echo "コミット ${GITHUB_SHA::7} から自動生成（サンプルデータ、iPhoneシミュレータ）。"
  echo
  for f in *.png; do echo "## ${f%.png}"; echo; echo "<img src=\"$f\" width=\"320\">"; echo; done
} > README.md
git init -q -b screenshots
git add .
git -c user.name="github-actions[bot]" -c user.email="41898282+github-actions[bot]@users.noreply.github.com" \
  commit -qm "Screenshots from ${GITHUB_SHA::7}"
git push -qf "https://x-access-token:${GITHUB_TOKEN}@github.com/${GITHUB_REPOSITORY}.git" screenshots
echo "https://github.com/${GITHUB_REPOSITORY}/tree/screenshots" >> "$GITHUB_STEP_SUMMARY"
