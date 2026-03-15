#!/usr/bin/env bash
#
# Copyright (C) 2026 crDroid Android Project
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
# Fetches Google Pixel Beta OTA metadata from developer.android.com
# and generates a gms_certified_props.json file for PlayIntegrityFix.
#
# Requirements: curl, grep, sed, awk, shuf (coreutils)
#
# Usage: ./fetch_beta_pif.sh [output_file]
#   output_file  - path to write JSON (default: gms_certified_props.json)
#

set -euo pipefail

GOOGLE_URL="https://developer.android.com"
OUTPUT_FILE="${1:-gms_certified_props.json}"

log()  { echo "[INFO]  $*" >&2; }
warn() { echo "[WARN]  $*" >&2; }
die()  { echo "[ERROR] $*" >&2; exit 1; }

# ── Step 1: Discover Android versions ────────────────────────────────
log "Fetching Android versions page..."
versions_html=$(curl -sfL "$GOOGLE_URL/about/versions") \
    || die "Failed to fetch $GOOGLE_URL/about/versions"

# Extract unique version numbers, sort descending
versions=$(echo "$versions_html" \
    | grep -oP 'https://developer\.android\.com/about/versions/\K\d+' \
    | sort -rnu)

[[ -z "$versions" ]] && die "No Android versions found on the page."
log "Found versions: $(echo $versions | tr '\n' ' ')"

# ── Step 2: For each version, look for QPR beta OTA pages ───────────
for version in $versions; do
    version_page="$GOOGLE_URL/about/versions/$version"
    log "Checking version page: $version_page"

    version_html=$(curl -sfL "$version_page" 2>/dev/null) || {
        warn "Failed to fetch version $version page, skipping..."
        continue
    }

    # Find QPR download-ota paths: /about/versions/<ver>/qpr<N>/download-ota
    # Capture QPR number and path, sort by QPR number descending
    qpr_entries=$(echo "$version_html" \
        | grep -oP 'href="(/about/versions/'"$version"'/qpr(\d+)/download-ota)"' \
        | sed -E 's/href="([^"]+)"/\1/' \
        | while IFS= read -r path; do
            qpr_num=$(echo "$path" | grep -oP 'qpr\K\d+')
            echo "$qpr_num $path"
        done | sort -rn -k1,1)

    if [[ -z "$qpr_entries" ]]; then
        log "No QPR beta pages found for version $version"
        continue
    fi

    # ── Step 3: For each QPR page, find beta OTA URLs ───────────────
    while IFS=' ' read -r qpr_num qpr_path; do
        ota_page="${GOOGLE_URL}${qpr_path}"
        log "Trying OTA page: $ota_page (QPR${qpr_num})"

        ota_html=$(curl -sfL "$ota_page" 2>/dev/null) || {
            warn "Failed to fetch QPR${qpr_num} page, trying next..."
            continue
        }

        # Extract beta OTA URLs and their product codenames
        # Pattern: href="https://dl.google.com/.../<product>_beta.../..."
        ota_matches=$(echo "$ota_html" \
            | grep -oP 'href="(https://dl\.google\.com/[^"]*ota/([^/"]+_beta)[^"]*?)"' \
            | sed -E 's/href="([^"]+)"/\1/' \
            || true)

        if [[ -z "$ota_matches" ]]; then
            log "No beta OTA URLs found on this page, trying next..."
            continue
        fi

        # Build an array of "model|product|ota_url" entries
        declare -a devices=()

        # Hardcoded codename -> model mapping
        declare -A CODENAME_MAP=(
            [oriole]="Pixel 6"
            [raven]="Pixel 6 Pro"
            [bluejay]="Pixel 6a"
            [panther]="Pixel 7"
            [cheetah]="Pixel 7 Pro"
            [lynx]="Pixel 7a"
            [shiba]="Pixel 8"
            [tangorpro]="Pixel Tablet"
            [felix]="Pixel Fold"
            [husky]="Pixel 8 Pro"
            [akita]="Pixel 8a"
            [tokay]="Pixel 9"
            [caiman]="Pixel 9 Pro"
            [komodo]="Pixel 9 Pro XL"
            [comet]="Pixel 9 Pro Fold"
            [tegu]="Pixel 9a"
            [frankel]="Pixel 10"
            [blazer]="Pixel 10 Pro"
            [mustang]="Pixel 10 Pro XL"
            [rango]="Pixel 10 Pro Fold"
            [stallion]="Pixel 10a"
        )

        while IFS= read -r ota_url; do
            product=$(echo "$ota_url" | grep -oP '[^/]+_beta' | head -1)
            [[ -z "$product" ]] && continue

            # Derive codename by stripping _beta suffix
            codename="${product%_beta}"

            # Look up model from codename map
            model="${CODENAME_MAP[$codename]:-}"

            if [[ -n "$model" ]]; then
                devices+=("${model}|${product}|${ota_url}")
                log "Matched: $model -> $product ($codename)"
            else
                warn "Unknown codename '$codename' from product '$product', skipping..."
            fi
        done <<< "$ota_matches"

        if [[ ${#devices[@]} -eq 0 ]]; then
            log "Could not match devices to OTA URLs, trying next..."
            unset devices
            continue
        fi

        # ── Step 4: Pick a random device ────────────────────────────
        picked="${devices[$((RANDOM % ${#devices[@]}))]}"
        IFS='|' read -r model product ota_url <<< "$picked"
        device="${product%_beta}"

        log "Selected: $model ($product) from Android $version QPR${qpr_num}"
        log "OTA URL: $ota_url"

        # ── Step 5: Fetch first 4 KB of OTA to extract metadata ─────
        log "Fetching first 4 KB from OTA..."
        partial_data=$(curl -sfL --range 0-4095 "$ota_url" \
            | strings 2>/dev/null) \
            || die "Failed to fetch partial OTA data."

        fingerprint=$(echo "$partial_data" \
            | grep -oP 'post-build=\K.*' | head -1 | tr -d '\r')
        security_patch=$(echo "$partial_data" \
            | grep -oP 'security-patch-level=\K.*' | head -1 | tr -d '\r')

        [[ -z "$fingerprint" ]]    && die "Could not extract fingerprint from OTA metadata."
        [[ -z "$security_patch" ]]  && die "Could not extract security patch from OTA metadata."

        log "Fingerprint:     $fingerprint"
        log "Security Patch:  $security_patch"

        # Parse sub-fields from the fingerprint
        # Format: brand/product/device:release/id/inc:type/tags
        fp_brand=$(echo "$fingerprint"   | cut -d'/' -f1)
        fp_release=$(echo "$fingerprint" | grep -oP ':\K[^/]+' | head -1)
        fp_id=$(echo "$fingerprint"      | grep -oP '/\K[A-Z][A-Z0-9.]+' | head -1)

        # ── Step 6: Write JSON ──────────────────────────────────────
        cat > "$OUTPUT_FILE" <<EOF
{
    "MANUFACTURER": "Google",
    "MODEL": "$model",
    "FINGERPRINT": "$fingerprint",
    "BRAND": "$fp_brand",
    "PRODUCT": "$product",
    "DEVICE": "$device",
    "VERSION.RELEASE": "$fp_release",
    "ID": "$fp_id",
    "VERSION.SECURITY_PATCH": "$security_patch",
    "VERSION.DEVICE_INITIAL_SDK_INT": "32"
}
EOF

        log "Written to $OUTPUT_FILE"
        echo ""
        cat "$OUTPUT_FILE"

        unset devices
        exit 0

    done <<< "$qpr_entries"

done

die "No valid beta OTA found across all versions."
