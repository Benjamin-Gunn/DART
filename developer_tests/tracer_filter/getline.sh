#!/bin/bash

# ref: https://www.baeldung.com/linux/read-specific-line-from-file
# extract the desired line number from a text file

FILE="$1"
LINE_NO=$2

i=0
while read line; do
  # skip comment lines beginning with "#"
  [[ ${line:0:1} == "#" ]] && continue

  i=$((i + 1))
  test $i = $LINE_NO && echo "$line" && exit 0
done < "$FILE"

echo "ERROR: line $LINE_NO not found, is $FILE too short? (only found $i non-comment lines)"
exit 1
