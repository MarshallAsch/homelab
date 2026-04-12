#!/bin/bash
#
# Migrate a Calibre library to a flat Author/Title structure
# compatible with Bookshelf (Readarr) and Kavita.
#
# Calibre stores books as:   Author Name/Book Title (123)/file.epub
# Target structure:           Author Name/Book Title/file.epub
#
# Usage:
#   ./migrate-calibre-library.sh <calibre-library-path> <destination-path>
#
# Options:
#   --dry-run    Show what would be done without copying anything
#   --move       Move files instead of copying (saves disk space)

set -euo pipefail

DRY_RUN=false
MOVE=false
CALIBRE_SRC=""
DEST=""

usage() {
    echo "Usage: $0 [--dry-run] [--move] <calibre-library-path> <destination-path>"
    echo ""
    echo "Options:"
    echo "  --dry-run  Show what would be done without copying anything"
    echo "  --move     Move files instead of copying"
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY_RUN=true; shift ;;
        --move)    MOVE=true; shift ;;
        -h|--help) usage ;;
        *)
            if [[ -z "$CALIBRE_SRC" ]]; then
                CALIBRE_SRC="$1"
            elif [[ -z "$DEST" ]]; then
                DEST="$1"
            else
                usage
            fi
            shift
            ;;
    esac
done

if [[ -z "$CALIBRE_SRC" || -z "$DEST" ]]; then
    usage
fi

if [[ ! -d "$CALIBRE_SRC" ]]; then
    echo "Error: Source directory does not exist: $CALIBRE_SRC"
    exit 1
fi

if [[ "$DRY_RUN" == false && ! -d "$DEST" ]]; then
    mkdir -p "$DEST"
fi

BOOK_EXTENSIONS="epub|pdf|mobi|azw3|azw|cbz|cbr|cb7|txt|djvu|fb2"
SKIPPED_FILES="metadata\.db|metadata_db_prefs_backup\.json|metadata\.opf"
COUNT=0
SKIPPED=0

echo "Migrating Calibre library:"
echo "  Source:      $CALIBRE_SRC"
echo "  Destination: $DEST"
echo "  Mode:        $(if $MOVE; then echo 'move'; else echo 'copy'; fi)"
echo "  Dry run:     $DRY_RUN"
echo ""

# Iterate over author directories
for author_dir in "$CALIBRE_SRC"/*/; do
    [[ ! -d "$author_dir" ]] && continue

    author=$(basename "$author_dir")

    # Skip Calibre metadata files at the root level
    [[ "$author" == "metadata.db" ]] && continue

    for book_dir in "$author_dir"/*/; do
        [[ ! -d "$book_dir" ]] && continue

        book_with_id=$(basename "$book_dir")

        # Strip Calibre's trailing ID: "Book Title (123)" -> "Book Title"
        book=$(echo "$book_with_id" | sed -E 's/ \([0-9]+\)$//')

        dest_dir="$DEST/$author/$book"

        # Find book files (skip Calibre metadata files)
        while IFS= read -r -d '' file; do
            filename=$(basename "$file")

            # Skip Calibre-specific metadata files
            if echo "$filename" | grep -qE "^($SKIPPED_FILES)$"; then
                ((SKIPPED++))
                continue
            fi

            # Skip non-book files (covers are kept)
            ext="${filename##*.}"
            ext_lower=$(echo "$ext" | tr '[:upper:]' '[:lower:]')
            if ! echo "$ext_lower" | grep -qE "^($BOOK_EXTENSIONS|jpg|jpeg|png|webp)$"; then
                ((SKIPPED++))
                echo "  SKIP: $file (unsupported format: $ext)"
                continue
            fi

            if [[ "$DRY_RUN" == true ]]; then
                echo "  $file -> $dest_dir/$filename"
            else
                mkdir -p "$dest_dir"
                if [[ "$MOVE" == true ]]; then
                    mv "$file" "$dest_dir/$filename"
                else
                    cp "$file" "$dest_dir/$filename"
                fi
                echo "  $file -> $dest_dir/$filename"
            fi
            ((COUNT++))
        done < <(find "$book_dir" -maxdepth 1 -type f -print0)
    done
done

echo ""
echo "Done. $COUNT files $(if $MOVE; then echo 'moved'; else echo 'copied'; fi). $SKIPPED files skipped."
if [[ "$DRY_RUN" == true ]]; then
    echo "(Dry run — no files were actually modified)"
fi
