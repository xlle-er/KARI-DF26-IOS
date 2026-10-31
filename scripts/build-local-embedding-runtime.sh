#!/bin/zsh
# Rebuild the pinned llama.cpp runtime with the app's existing iOS 15 minimum.
set -euo pipefail
cd "$(dirname "$0")/.."
kari_project="$PWD"
kari_source="$(mktemp -d /tmp/kari-llama-runtime.XXXXXX)"
git clone --filter=blob:none https://github.com/ggml-org/llama.cpp.git "$kari_source"
git -C "$kari_source" checkout 78feec062d50ec9e8940244cac918ac4480b60cb
python3 - "$kari_source/build-xcframework.sh" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]);s=p.read_text().replace('IOS_MIN_OS_VERSION=16.4','IOS_MIN_OS_VERSION=15.0')
s=s.replace('JOBS_PER_BUILD=$(( $(sysctl -n hw.logicalcpu) / MAX_PARALLEL_BUILDS ))','JOBS_PER_BUILD=4')
p.write_text(s)
PY
(cd "$kari_source" && bash build-xcframework.sh ios-device ios-sim macos)
python3 - "$kari_source" "$kari_project/Native/Vendor" <<'PY'
from pathlib import Path
import sys,shutil,plistlib
source=Path(sys.argv[1]);vendor=Path(sys.argv[2]);target=vendor/'llama.xcframework'
if target.exists():shutil.rmtree(target)
shutil.copytree(source/'build-apple/llama.xcframework',target)
with (target/'Info.plist').open('rb') as f:info=plistlib.load(f)
for library in info['AvailableLibraries']:
 library.pop('DebugSymbolsPath',None)
 symbols=target/library['LibraryIdentifier']/'dSYMs'
 if symbols.exists():shutil.rmtree(symbols)
with (target/'Info.plist').open('wb') as f:plistlib.dump(info,f)
shutil.copy(source/'LICENSE',vendor.parent.parent/'licenses/LLAMA-LICENSE')
PY
echo "Pinned llama runtime ready in Native/Vendor."
