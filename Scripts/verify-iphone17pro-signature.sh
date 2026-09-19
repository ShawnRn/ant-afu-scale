#!/bin/zsh

set -euo pipefail

readonly expected_team_identifier="8CAEUC6576"
readonly expected_bundle_identifier="app.tourmaline5269.brown6028"
readonly expected_application_identifier="${expected_team_identifier}.${expected_bundle_identifier}"

if [[ $# -ne 1 ]]; then
    print -u2 "用法：$0 /绝对路径/已签名.ipa"
    exit 64
fi

readonly signed_ipa="$1"
if [[ ! -f "${signed_ipa}" ]]; then
    print -u2 "未找到 IPA：${signed_ipa}"
    exit 1
fi

temporary_root="$(mktemp -d /tmp/scale-iphone17pro-verify.XXXXXX)"
cleanup() {
    if [[ "${temporary_root}" == /tmp/scale-iphone17pro-verify.* && -d "${temporary_root}" ]]; then
        rm -r "${temporary_root}"
    fi
}
trap cleanup EXIT

unzip -q "${signed_ipa}" -d "${temporary_root}/archive"
app_path="$(find "${temporary_root}/archive/Payload" -maxdepth 1 -type d -name '*.app' | head -n 1)"
if [[ -z "${app_path}" ]]; then
    print -u2 "IPA 中未找到 Payload/*.app"
    exit 1
fi
if [[ ! -f "${app_path}/embedded.mobileprovision" ]]; then
    print -u2 "App 中未嵌入描述文件"
    exit 1
fi

readonly signed_entitlements="${temporary_root}/signed-entitlements.plist"
readonly decoded_profile="${temporary_root}/profile.plist"
codesign -d --entitlements :- "${app_path}" 2>/dev/null > "${signed_entitlements}"
security cms -D -i "${app_path}/embedded.mobileprovision" > "${decoded_profile}"

bundle_identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${app_path}/Info.plist")"
signed_application_identifier="$(/usr/libexec/PlistBuddy -c 'Print :application-identifier' "${signed_entitlements}")"
profile_application_identifier="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:application-identifier' "${decoded_profile}")"
signed_team_identifier="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.developer.team-identifier' "${signed_entitlements}")"
signed_healthkit="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.developer.healthkit' "${signed_entitlements}")"

if [[ "${bundle_identifier}" != "${expected_bundle_identifier}" ]]; then
    print -u2 "Bundle ID 不匹配：${bundle_identifier}"
    exit 1
fi
if [[ "${signed_application_identifier}" != "${expected_application_identifier}" ]]; then
    print -u2 "代码签名 App ID 不匹配：${signed_application_identifier}"
    exit 1
fi
if [[ "${profile_application_identifier}" != "${expected_application_identifier}" ]]; then
    print -u2 "描述文件 App ID 不匹配：${profile_application_identifier}"
    exit 1
fi
if [[ "${signed_team_identifier}" != "${expected_team_identifier}" ]]; then
    print -u2 "代码签名 Team ID 不匹配：${signed_team_identifier}"
    exit 1
fi
if [[ "${signed_healthkit:l}" != "true" ]]; then
    print -u2 "代码签名未保留 HealthKit Entitlement"
    exit 1
fi

codesign --verify --deep --strict --verbose=2 "${app_path}"

print "iPhone 17 Pro 专用自签校验通过"
print "Bundle ID：${bundle_identifier}"
print "Application ID：${signed_application_identifier}"
print "Team ID：${signed_team_identifier}"
print "HealthKit：${signed_healthkit}"
print "SHA-256：$(shasum -a 256 "${signed_ipa}" | awk '{print $1}')"
