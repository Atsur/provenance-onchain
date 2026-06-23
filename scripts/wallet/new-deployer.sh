#!/usr/bin/env bash
#
# new-deployer.sh — generate, list, and retire single-use burner deployer wallets,
# one per network, for use with Deploy.s.sol / deployAll.js.
#
# This is plain bash wrapping `cast wallet new` on purpose: the private key never
# passes through Node, never gets console.log'd, and never leaves your machine.
# Run this in your own terminal — never paste its output into a chat session.
#
# Usage:
#   scripts/wallet/new-deployer.sh new <network> [--force]
#   scripts/wallet/new-deployer.sh list
#   scripts/wallet/new-deployer.sh retire <network>
#
# Examples:
#   scripts/wallet/new-deployer.sh new sepolia
#   scripts/wallet/new-deployer.sh new polygon
#   scripts/wallet/new-deployer.sh list
#   scripts/wallet/new-deployer.sh retire sepolia
#
set -euo pipefail

OUT_DIR=".deployer-wallets"
LEDGER="$OUT_DIR/ledger.json"

usage() {
    echo "Usage:"
    echo "  $0 new <network> [--force]   Generate a fresh burner deployer wallet for <network>"
    echo "  $0 list                      List known deployer wallets (addresses only, no keys)"
    echo "  $0 retire <network>          Delete the saved private key for <network> (irreversible)"
    exit 1
}

require_cast() {
    if ! command -v cast >/dev/null 2>&1; then
        echo "Error: 'cast' (Foundry) not found. Install via:"
        echo "  curl -L https://foundry.paradigm.xyz | bash && foundryup"
        exit 1
    fi
}

ensure_gitignored() {
    if [ -f .gitignore ] && ! grep -qxF "$OUT_DIR/" .gitignore; then
        printf "\n# Burner deployer wallets (private keys) — never commit\n%s/\n" "$OUT_DIR" >> .gitignore
        echo "Added $OUT_DIR/ to .gitignore."
    fi
}

ensure_ledger() {
    mkdir -p "$OUT_DIR"
    chmod 700 "$OUT_DIR"
    if [ ! -f "$LEDGER" ]; then
        echo "[]" > "$LEDGER"
    fi
}

cmd_new() {
    local network="${1:-}"
    local force="${2:-}"
    [ -z "$network" ] && usage
    require_cast
    ensure_gitignored
    ensure_ledger

    local out_file="$OUT_DIR/$network.env"
    if [ -f "$out_file" ] && [ "$force" != "--force" ]; then
        echo "A deployer wallet for '$network' already exists at $out_file."
        echo "If you're sure the old one is retired, re-run with --force to replace it."
        exit 1
    fi

    echo "Generating a fresh burner deployer wallet for network: $network"
    local result address private_key
    result="$(cast wallet new --json)"

    if command -v jq >/dev/null 2>&1; then
        address="$(echo "$result" | jq -r '.[0].address')"
        private_key="$(echo "$result" | jq -r '.[0].private_key')"
    else
        address="$(echo "$result" | grep -o '"address": *"[^"]*"' | sed -E 's/.*"([^"]+)"$/\1/')"
        private_key="$(echo "$result" | grep -o '"private_key": *"[^"]*"' | sed -E 's/.*"([^"]+)"$/\1/')"
    fi

    {
        echo "# Burner deployer wallet for: $network"
        echo "# Generated: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
        echo "# Single-use. Retire with: $0 retire $network"
        echo "PRIVATE_KEY=$private_key"
        echo "DEPLOYER_ADDRESS=$address"
    } > "$out_file"
    chmod 600 "$out_file"

    if command -v jq >/dev/null 2>&1; then
        local tmp
        tmp="$(mktemp)"
        jq --arg net "$network" --arg addr "$address" --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
            '. + [{network: $net, address: $addr, createdAt: $ts, status: "active"}]' \
            "$LEDGER" > "$tmp"
        mv "$tmp" "$LEDGER"
    fi

    echo ""
    echo "=== Deployer wallet ready: $network ==="
    echo "Address: $address"
    echo "Saved to: $out_file (chmod 600, gitignored)"
    echo ""
    echo "Next steps:"
    echo "  1. Fund $address with just enough gas on $network."
    echo "  2. Before deploying, merge it into your real .env:"
    echo "       cat $out_file >> .env"
    echo "  3. Run the $network deploy as usual (see DEPLOYMENT.md)."
    echo "  4. After the deploy, confirm the deployer holds zero roles (Phase 4"
    echo "     checklist in DEPLOYMENT.md), then run:"
    echo "       $0 retire $network"
}

cmd_list() {
    ensure_ledger
    if command -v jq >/dev/null 2>&1; then
        echo "Network      Address                                      Status    Created"
        jq -r '.[] | [.network, .address, .status, .createdAt] | @tsv' "$LEDGER" | \
            awk -F'\t' '{printf "%-12s %-44s %-9s %s\n", $1, $2, $3, $4}'
    else
        cat "$LEDGER"
    fi
}

cmd_retire() {
    local network="${1:-}"
    [ -z "$network" ] && usage
    ensure_ledger

    local out_file="$OUT_DIR/$network.env"
    if [ -f "$out_file" ]; then
        shred -u "$out_file" 2>/dev/null || rm -f "$out_file"
        echo "Deleted private key file for '$network'."
    else
        echo "No active key file found for '$network' (already retired?)."
    fi

    if command -v jq >/dev/null 2>&1; then
        local tmp
        tmp="$(mktemp)"
        jq --arg net "$network" \
            'map(if .network == $net then .status = "retired" else . end)' \
            "$LEDGER" > "$tmp"
        mv "$tmp" "$LEDGER"
    fi

    echo "Don't forget to also remove PRIVATE_KEY/DEPLOYER_ADDRESS for '$network' from .env"
    echo "if you merged them in."
}

case "${1:-}" in
    new)    shift; cmd_new "$@" ;;
    list)   shift; cmd_list "$@" ;;
    retire) shift; cmd_retire "$@" ;;
    *)      usage ;;
esac
