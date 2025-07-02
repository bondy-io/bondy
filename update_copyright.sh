#!/bin/bash
# This script scans for files and ensures each one contains a proper copyright header.
# It supports headers with a single year or a range of years.
# It is compatible with both macOS (BSD sed) and Linux (GNU sed).

CURRENT_YEAR=$(date +%Y)
COMPANY="Leapsight"

# Define a header template for new files. This uses a year range (both dates the same initially).
HEADER_TEMPLATE=$(cat <<EOF
%% =============================================================================
%% SPDX-FileCopyrightText: $CURRENT_YEAR $COMPANY
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================
EOF
)

echo "$HEADER_TEMPLATE"

# Adjust the file extensions to suit your projectm skipping the directories
# _build, deps
find . \
  \( -path "./_build" -o -path "./deps" \) -prune -false -o \
  \( -type f \( -name "*.ex" -o -name "*.exs" \) \) | while read -r file; do
  if grep -q "SPDX-FileCopyrightText:" "$file"; then
      # If a header exists, check if it uses a range (i.e. "YYYY - YYYY")
      if grep -q -E "SPDX-FileCopyrightText\: ([0-9]{4})[[:space:]]*-[[:space:]]*([0-9]{4})" "$file"; then
          # Extract the two years from the range
          header_line=$(grep -o -E "SPDX-FileCopyrightText\: [0-9]{4}[[:space:]]*-[[:space:]]*[0-9]{4}" "$file")
          from_year=$(echo "$header_line" | sed -E 's/.*SPDX-FileCopyrightText\: ([0-9]{4}).*/\1/')
          to_year=$(echo "$header_line" | sed -E 's/.*-[[:space:]]*([0-9]{4}).*/\1/')
          if [ "$from_year" -eq "$to_year" ]; then
              # If the header is a range but both years are the same...
              if [ "$from_year" -eq "$CURRENT_YEAR" ]; then
                  echo "Header in $file is already up-to-date."
              else
                  # If not current, update it to a range if needed
                  if [ "$CURRENT_YEAR" -gt "$from_year" ]; then
                      sed -i.bak -E "s/(SPDX-FileCopyrightText\: )${from_year}[[:space:]]*-[[:space:]]*${to_year}/\1${from_year} - ${CURRENT_YEAR}/" "$file"
                      rm "$file.bak"
                      echo "Updated header in $file to range ${from_year} - ${CURRENT_YEAR}"
                  fi
              fi
          else
              # If it’s already a proper range (different years), update only if CURRENT_YEAR is greater than the current to_year.
              if [ "$CURRENT_YEAR" -gt "$to_year" ]; then
                  sed -i.bak -E "s/(SPDX-FileCopyrightText\: ${from_year}[[:space:]]*-[[:space:]]*)${to_year}/\1${CURRENT_YEAR}/" "$file"
                  rm "$file.bak"
                  echo "Updated header range in $file to ${from_year} - ${CURRENT_YEAR}"
              else
                  echo "Header in $file is already up-to-date."
              fi
          fi
      else
          # Otherwise, assume the header contains a single year.
          if grep -q -E "SPDX-FileCopyrightText\: [0-9]{4}" "$file"; then
              existing_year=$(grep -o -E "SPDX-FileCopyrightText\: [0-9]{4}" "$file" | grep -o -E "[0-9]{4}")
              if [ "$existing_year" -eq "$CURRENT_YEAR" ]; then
                  echo "Header in $file is already up-to-date."
              else
                  # Convert the single year to a range if the existing year is less than the current year.
                  sed -i.bak -E "s/(SPDX-FileCopyrightText\: )${existing_year}/\1${existing_year} - ${CURRENT_YEAR}/" "$file"
                  rm "$file.bak"
                  echo "Updated header in $file to range ${existing_year} - ${CURRENT_YEAR}"
              fi
          fi
      fi
  else
      # If no header exists, prepend the new header (with a single year)
      (echo -e "$HEADER_TEMPLATE\n"; cat "$file") > "$file.new" && mv "$file.new" "$file"
      echo "Added header to $file"
  fi
done