#!/bin/zsh

set -euo pipefail

readonly script_directory="${0:A:h}"
readonly repository_root="${script_directory:h}"
readonly device_identifier="00008150-001E58CA3E84401C"
readonly expected_team_identifier="8CAEUC6576"
readonly expected_bundle_identifier="app.tourmaline5269.brown6028"
readonly expected_application_identifier="${expected_team_identifier}.${expected_bundle_identifier}"
readonly default_profile_path="/Users/shawnrain/Library/Mobile Documents/com~apple~CloudDocs/Shawn Rain/个人/iPhone 17 Pro 证书/描述文件.mobileprovision"
readonly profile_path="${SCALE_IPHONE17_PROFILE:-${default_profile_path}}"

if [[ ! -f "${profile_path}" ]]; then
    print -u2 "未找到 iPhone 17 Pro 专用描述文件：${profile_path}"
    exit 1
fi

temporary_root="$(mktemp -d /tmp/scale-iphone17pro.XXXXXX)"
cleanup() {
    if [[ "${temporary_root}" == /tmp/scale-iphone17pro.* && -d "${temporary_root}" ]]; then
        rm -r "${temporary_root}"
    fi
}
trap cleanup EXIT

readonly decoded_profile="${temporary_root}/profile.plist"
security cms -D -i "${profile_path}" > "${decoded_profile}"

profile_application_identifier="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:application-identifier' "${decoded_profile}")"
profile_team_identifier="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.developer.team-identifier' "${decoded_profile}")"
profile_healthkit="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.developer.healthkit' "${decoded_profile}")"

if [[ "${profile_application_identifier}" != "${expected_application_identifier}" ]]; then
    print -u2 "描述文件 App ID 不匹配：${profile_application_identifier}"
    exit 1
fi
if [[ "${profile_team_identifier}" != "${expected_team_identifier}" ]]; then
    print -u2 "描述文件 Team ID 不匹配：${profile_team_identifier}"
    exit 1
fi
if [[ "${profile_healthkit:l}" != "true" ]]; then
    print -u2 "描述文件未授权 HealthKit"
    exit 1
fi

readonly swift_validation_directory="${temporary_root}/swift-validation"
mkdir -p "${swift_validation_directory}"
(
    cd "${swift_validation_directory}"
    xcrun -sdk iphoneos swiftc \
        -target arm64-apple-ios26.0 \
        -warnings-as-errors \
        -c "${repository_root}"/Scale/*.swift \
        -parse-as-library
)

readonly derived_data_path="${temporary_root}/DerivedData"
readonly build_log="${temporary_root}/xcodebuild.log"
set -o pipefail
xcodebuild \
    -project "${repository_root}/Scale.xcodeproj" \
    -scheme "Scale App" \
    -configuration Release \
    -destination "id=${device_identifier}" \
    -derivedDataPath "${derived_data_path}" \
    PRODUCT_BUNDLE_IDENTIFIER="${expected_bundle_identifier}" \
    CODE_SIGNING_ALLOWED=NO \
    build 2>&1 | tee "${build_log}"

if grep -Ei '(^|: )warning:' "${build_log}"; then
    print -u2 "构建日志中存在 Warning，已停止打包"
    exit 1
fi

readonly built_app="${derived_data_path}/Build/Products/Release-iphoneos/Scale.app"
if [[ ! -d "${built_app}" ]]; then
    print -u2 "未找到 Release App：${built_app}"
    exit 1
fi

built_bundle_identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${built_app}/Info.plist")"
if [[ "${built_bundle_identifier}" != "${expected_bundle_identifier}" ]]; then
    print -u2 "构建产物 Bundle ID 不匹配：${built_bundle_identifier}"
    exit 1
fi

readonly payload_directory="${temporary_root}/package/Payload"
mkdir -p "${payload_directory}"
ditto "${built_app}" "${payload_directory}/Scale.app"

readonly output_directory="${repository_root}/dist"
mkdir -p "${output_directory}"
readonly timestamp="$(date '+%Y%m%d-%H%M%S')"
readonly output_ipa="${output_directory}/Scale-iPhone17Pro-AllSign-${timestamp}.ipa"
(
    cd "${temporary_root}/package"
    /usr/bin/zip -qry "${output_ipa}" Payload
)

print "已生成全能签专用 IPA：${output_ipa}"
print "Bundle ID：${expected_bundle_identifier}"
print "SHA-256：$(shasum -a 256 "${output_ipa}" | awk '{print $1}')"
print "请在全能签中保留原 Bundle ID，签名后再运行 Scripts/verify-iphone17pro-signature.sh 复核。"
