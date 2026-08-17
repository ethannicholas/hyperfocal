#!/bin/bash
#
# How a locally built copy of the macOS app is signed. Sourced (not run) by
# Scripts/build.sh and Scripts/ui-test.sh, which pass "${HF_SIGN_ARGS[@]}"
# to xcodebuild. Distribution signing is elsewhere: Scripts/package-app.sh
# (Developer ID) and the App Store upload tooling.
#
# The default is ad-hoc — Xcode's "Sign to Run Locally" — and it lives in
# App/project.yml (CODE_SIGN_IDENTITY "-", CODE_SIGN_STYLE Manual) rather
# than here, so that opening the generated project in Xcode.app and pressing
# Run works too. Nobody cloning the repo holds a certificate for this
# project's team, so a default that demands one makes the first build fail
# with `No signing certificate "Mac Development" found` — which would be
# the whole experience of trying Hyperfocal from source.
# Ad-hoc costs nothing locally — the sandbox container is keyed to the bundle
# ID, and Xcode still injects get-task-allow into Debug builds, so the
# debugger attaches.
#
# A machine that does hold a development certificate for the project's *own*
# team signs with it instead. That is not vanity: an ad-hoc signature's
# designated requirement pins the cdhash, which changes with every build, so
# macOS re-asks for the Automation permission that Scripts/run.sh (it quits a
# running instance by AppleEvent) and the UI tests depend on. Certificates
# from any other team are ignored deliberately — they cannot sign
# com.ethannicholas.hyperfocal, since the bundle ID is ours, and attempting it
# is exactly the failure this file exists to prevent.
#
#   HYPERFOCAL_DEVELOPMENT_TEAM=<id>   sign with this team, no keychain check
#   HYPERFOCAL_DEVELOPMENT_TEAM=       (set but empty) force ad-hoc

# The team the project distributes under. App/project.yml is the single
# source for it.
hf_project_team() {
    sed -n 's/.*DEVELOPMENT_TEAM: *//p' App/project.yml | sort -u | head -1
}

# Reads concatenated PEM certificates on stdin, writes their team IDs (the
# subject's OU) one per line. openssl x509 reads a single certificate per
# invocation and ignores whatever follows, so the blocks are fed one at a
# time — macOS awk has no multi-character RS to split them in one pass.
hf_certificate_teams() {
    local pems pem n=1
    pems=$(cat)
    while pem=$(printf '%s\n' "$pems" \
        | awk -v n="$n" '/BEGIN CERT/ { c++ } c == n { print } /END CERT/ { if (c == n) exit }')
        [ -n "$pem" ]
    do
        printf '%s\n' "$pem" \
            | openssl x509 -noout -subject -nameopt sep_multiline,utf8 2>/dev/null \
            | sed -n 's/^ *OU=//p'
        n=$((n + 1))
    done
}

# Sets HF_SIGN_ARGS — the xcodebuild overrides that pick an identity, empty
# when the project's ad-hoc default applies — and says which it chose.
hf_signing_args() {
    HF_SIGN_ARGS=()
    local team
    if [ -n "${HYPERFOCAL_DEVELOPMENT_TEAM+set}" ]; then
        team="$HYPERFOCAL_DEVELOPMENT_TEAM"
    else
        team=$(hf_project_team)
        # Both halves matter: a certificate whose private key is missing is
        # listed by find-certificate but cannot sign anything.
        if ! security find-identity -v -p codesigning 2>/dev/null | grep -q '"Apple Development' \
           || ! security find-certificate -a -p -c "Apple Development" 2>/dev/null \
                | hf_certificate_teams | grep -qx "$team"; then
            team=""
        fi
    fi

    if [ -n "$team" ]; then
        HF_SIGN_ARGS=(CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM="$team"
                      CODE_SIGN_IDENTITY="Apple Development")
        echo "== signing with the development certificate for team $team"
    else
        echo "== signing ad-hoc (no development certificate for team $(hf_project_team))"
    fi
}
