#!/bin/bash
# Replaces the `screenshots` branch with the latest captures so they can be viewed on GitHub, even from a phone.
set -euo pipefail

src="$PWD/ci-results"
work=$(mktemp -d)
for family in iPhone iPad; do
  for f in "$src/$family"/*.png; do [ -e "$f" ] && cp "$f" "$work/$family-$(basename "$f")"; done
done
cd "$work"
{
  echo "# 画面のスクリーンショット"
  echo
  echo "コミット ${GITHUB_SHA::7}（${GITHUB_REF_NAME}）から自動生成。サンプルデータ、iPhone・iPadシミュレータ。"
  echo
  for f in *.png; do echo "## ${f%.png}"; echo; echo "<img src=\"$f\" width=\"320\">"; echo; done
} > README.md
git init -q -b screenshots
git add .
git -c user.name="github-actions[bot]" -c user.email="41898282+github-actions[bot]@users.noreply.github.com" \
  commit -qm "Screenshots from ${GITHUB_SHA::7}"
git push -qf "https://x-access-token:${GITHUB_TOKEN}@github.com/${GITHUB_REPOSITORY}.git" screenshots
echo "https://github.com/${GITHUB_REPOSITORY}/tree/screenshots" >> "$GITHUB_STEP_SUMMARY"
