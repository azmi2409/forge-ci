#!/usr/bin/env bash
# forge-ci's stand-in for the CircleCI CLI's test-splitting commands. The
# runner copies it into every job container as /usr/local/bin/circleci.
#
#   circleci tests glob "test/**/*_test.rb" ...    list matching files
#   circleci tests split [--split-by=name|filesize|timings] [files...]
#                                                   this node's share (stdin or args)
#   circleci tests run --command="xargs bin/rails test" [--split-by=...]
#                                                   split stdin, pipe this node's share to
#                                                   the command; skip it when the share is empty
#
# Nodes come from CIRCLE_NODE_INDEX / CIRCLE_NODE_TOTAL (override with
# --index / --total). Every node sees the same file list at the same commit,
# so each computes the same deterministic split. forge-ci records no test
# timings yet: --split-by=timings falls back to filesize.
set -euo pipefail

die() {
  echo "circleci: $*" >&2
  exit 2
}

split_by=name
total=${CIRCLE_NODE_TOTAL:-1}
index=${CIRCLE_NODE_INDEX:-0}
command=""
args=()

parse_options() {
  while (($#)); do
    case "$1" in
      --split-by=*) split_by=${1#*=} ;;
      --split-by) split_by=${2:?--split-by needs a value}; shift ;;
      --total=*) total=${1#*=} ;;
      --total) total=${2:?--total needs a value}; shift ;;
      --index=*) index=${1#*=} ;;
      --index) index=${2:?--index needs a value}; shift ;;
      --command=*) command=${1#*=} ;;
      --command) command=${2:?--command needs a value}; shift ;;
      --timings-type=* | --show-counts | --verbose) ;;
      --timings-type) shift ;;
      --*) die "unknown option $1" ;;
      *) args+=("$1") ;;
    esac
    shift
  done
  [[ $total =~ ^[0-9]+$ && $total -ge 1 ]] || die "--total must be a positive number (got $total)"
  [[ $index =~ ^[0-9]+$ && $index -lt $total ]] || die "--index must be 0..$((total - 1)) (got $index)"
  case "$split_by" in
    name | filesize) ;;
    timings)
      echo "circleci: no test timings recorded on forge-ci yet; splitting by filesize" >&2
      split_by=filesize
      ;;
    *) die "--split-by must be name, filesize or timings (got $split_by)" ;;
  esac
}

# File names from the arguments, or whitespace-separated from stdin.
file_list() {
  if ((${#args[@]})); then
    printf '%s\n' "${args[@]}"
  else
    tr -s ' \t' '\n\n'
  fi | sed '/^$/d' | sort -u
}

# Reads a sorted, unique file list on stdin; prints this node's share.
split_files() {
  case "$split_by" in
    name)
      # Round robin over the sorted names.
      awk -v total="$total" -v index_="$index" '(NR - 1) % total == index_'
      ;;
    filesize)
      # Largest first, each file to the node with the least bytes so far
      # (ties go to the lowest node).
      while IFS= read -r f; do
        printf '%s\t%s\n' "$(wc -c <"$f" 2>/dev/null || echo 0)" "$f"
      done | sort -t $'\t' -k1,1nr -k2,2 |
        awk -F '\t' -v total="$total" -v index_="$index" '{
          best = 0
          for (n = 1; n < total; n++) if (load[n] < load[best]) best = n
          load[best] += $1
          if (best == index_) print $2
        }'
      ;;
  esac
}

tests_glob() {
  (($#)) || die "tests glob needs at least one pattern"
  shopt -s globstar nullglob
  local pattern f
  for pattern in "$@"; do
    # Unquoted on purpose: the pattern is expanded as a glob.
    # shellcheck disable=SC2086
    for f in $pattern; do
      [[ -f $f ]] && printf '%s\n' "$f"
    done
  done | sort -u
}

tests_split() {
  parse_options "$@"
  file_list | split_files
}

tests_run() {
  parse_options "$@"
  [[ -n $command ]] || die 'tests run needs --command, e.g. --command="xargs bin/rails test"'
  local share
  share=$(file_list | split_files)
  if [[ -z $share ]]; then
    echo "circleci: no tests for node $index of $total; skipping" >&2
    return 0
  fi
  printf '%s\n' "$share" | bash -c "$command"
}

case "${1:-} ${2:-}" in
  "tests glob") shift 2; tests_glob "$@" ;;
  "tests split") shift 2; tests_split "$@" ;;
  "tests run") shift 2; tests_run "$@" ;;
  *) die "forge-ci supports only 'circleci tests glob|split|run'" ;;
esac
