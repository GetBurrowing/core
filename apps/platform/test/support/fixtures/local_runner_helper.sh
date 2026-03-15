#!/bin/sh

mode="$1"
ready_file="$2"
state_file="$3"

mkdir -p "$(dirname "$ready_file")"
mkdir -p "$(dirname "$state_file")"

printf "ready\n" > "$ready_file"

term_handler() {
  printf "term\n" > "$state_file"
  exit 0
}

trap term_handler TERM INT

case "$mode" in
  loop)
    while true
    do
      sleep 0.05
    done
    ;;
  exit0)
    printf "completed\n" > "$state_file"
    exit 0
    ;;
  *)
    printf "unknown:%s\n" "$mode" > "$state_file"
    exit 2
    ;;
esac
