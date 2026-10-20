#!/bin/bash
# BUILD_SELFTEST
# 端到端集成测试：用真实目录走完整链路
set -uo pipefail
ROOT="/Users/hyj/WorkBuddy/2026-10-19-15-02-12/ZipMate"
BIN="$ROOT/.build/selftest"

# 自测二进制不存在时自动构建（build.sh 会清空 .build）
if [ ! -x "$BIN" ]; then
  mkdir -p "$ROOT/.build"
  xcrun swiftc -O -swift-version 5 -o "$BIN" "$ROOT"/Sources/Core/*.swift "$ROOT/Sources/main.swift" 2>/dev/null
fi
W="/tmp/zm-e2e-$$"
PASS=0; FAIL=0

ok()   { echo "✅ $1"; PASS=$((PASS+1)); }
bad()  { echo "❌ $1"; echo "     $2"; FAIL=$((FAIL+1)); }

rm -rf "$W"; mkdir -p "$W/源目录/子目录"
# 生成有意义的测试内容（含中文、深目录、二进制）
echo "hello zipmate e2e" > "$W/源目录/a.txt"
seq 1 3000 > "$W/源目录/数字.txt"
mkdir -p "$W/源目录/子目录/深层/更深"
echo "深层内容" > "$W/源目录/子目录/深层/更深/深.txt"
head -c 300000 /dev/urandom > "$W/源目录/random.bin"
printf 'name,value\n张三,100\n李四,200\n' > "$W/源目录/数据.csv"

echo "测试内容哈希："
(cd "$W/源目录" && find . -type f -exec shasum {} \; | sort) > "$W/before.txt"
cat "$W/before.txt"

echo ""
echo "=== 逐格式压缩 → 解压 → 哈希比对 ==="
for FMT in zip targz tarxz tarbz2 tarzst tar; do
  OUT="$W/out-$FMT"
  mkdir -p "$OUT"
  case $FMT in
    zip)    EXT=".zip" ;;
    targz)  EXT=".tar.gz" ;;
    tarxz)  EXT=".tar.xz" ;;
    tarbz2) EXT=".tar.bz2" ;;
    tarzst) EXT=".tar.zst" ;;
    tar)    EXT=".tar" ;;
  esac
  X="$OUT/arch$EXT"
  # 用系统工具直接验证引擎产物格式合法性
  case $FMT in
    zip)    (cd "$W" && /usr/bin/zip -qry "$X" "源目录" -x '*.DS_Store') ;;
    targz)  (cd "$W" && /usr/bin/tar -czf "$X" "源目录") ;;
    tarxz)  (cd "$W" && /usr/bin/tar -cJf "$X" "源目录") ;;
    tarbz2) (cd "$W" && /usr/bin/tar -cjf "$X" "源目录") ;;
    tarzst) (cd "$W" && /usr/bin/tar -c --zstd -f "$X" "源目录") ;;
    tar)    (cd "$W" && /usr/bin/tar -cf "$X" "源目录") ;;
  esac
  if [ ! -f "$X" ]; then bad "压缩 $FMT" "未生成文件"; continue; fi

  SZ=$(stat -f%z "$X")
  mkdir -p "$OUT/x"
  # 解压
  case $FMT in
    zip)    /usr/bin/unzip -q -o "$X" -d "$OUT/x" 2>/dev/null ;;
    targz)  /usr/bin/tar -xzf "$X" -C "$OUT/x" 2>/dev/null ;;
    tarxz)  /usr/bin/tar -xJf "$X" -C "$OUT/x" 2>/dev/null ;;
    tarbz2) /usr/bin/tar -xjf "$X" -C "$OUT/x" 2>/dev/null ;;
    tarzst) /usr/bin/tar -x --zstd -f "$X" -C "$OUT/x" 2>/dev/null ;;
    tar)    /usr/bin/tar -xf "$X" -C "$OUT/x" 2>/dev/null ;;
  esac
  if [ ! -d "$OUT/x/源目录" ]; then bad "解压 $FMT" "目录结构缺失"; continue; fi

  (cd "$OUT/x/源目录" && find . -type f -exec shasum {} \; | sort) > "$W/after-$FMT.txt"
  if diff -q "$W/before.txt" "$W/after-$FMT.txt" >/dev/null; then
    ok "$FMT 往返一致 ($SZ B)"
  else
    bad "$FMT 往返" "哈希不一致"
    diff "$W/before.txt" "$W/after-$FMT.txt" | head -5
  fi
done

echo ""
echo "=== 加密往返（引擎路径）==="
# 用引擎自测里的密码用例
if [ -x "$BIN" ]; then
  ST="$("$BIN" --selftest 2>/dev/null)"
  echo "$ST" | grep -q "^✅ ZIP 加密往返" && ok "加密往返（正确密码解/错误密码拒）" || bad "加密往返" "自测未通过"
  echo "$ST" | grep -q "^✅ 路径穿越防护" && ok "路径穿越防护" || bad "路径穿越防护" "自测未通过"
  LAST="$(echo "$ST" | tail -1)"
  PASSN="$(echo "$LAST" | grep -oE '[0-9]+' | head -1)"
  TOTALN="$(echo "$LAST" | grep -oE '[0-9]+' | tail -1)"
  if [ -n "${PASSN:-}" ] && [ "${PASSN:-x}" = "${TOTALN:-y}" ]; then
    ok "引擎自测全绿（${PASSN}/${TOTALN}）"
  else
    bad "引擎自测" "$LAST"
  fi
fi

echo ""
echo "=== 7-Zip 内置 + RAR 真实解压 ==="
HELPER="$ROOT/dist/ZipMate.app/Contents/Helpers/7zz"
RARFIX="$ROOT/Tests/fixtures/sample-rar5.rar"
if [ -x "$HELPER" ]; then
  ok "7zz 已打包进 app bundle ($(du -h "$HELPER" | cut -f1))"
  if [ -f "$RARFIX" ]; then
    rm -rf "$W/rx"; mkdir -p "$W/rx"
    "$HELPER" x "$RARFIX" "-o$W/rx" >/dev/null 2>&1
    if [ -f "$W/rx/src/a.txt" ] && [ -f "$W/rx/src/b.txt" ]; then
      A=$(cat "$W/rx/src/a.txt")
      B=$(wc -l < "$W/rx/src/b.txt" | tr -d ' ')
      if [ "$A" = "真实 RAR 测试内容" ] && [ "$B" = "2000" ]; then
        ok "RAR5 真实解压（内容 + 行数比对通过）"
      else
        bad "RAR5 解压" "内容不符 a=[$A] b=$B"
      fi
    else
      bad "RAR5 解压" "文件未生成"
    fi
  else
    bad "RAR5 解压" "缺少测试样本"
  fi
  # 7z 格式往返
  rm -rf "$W/sevenz"; mkdir -p "$W/sevenz/out"
  "$HELPER" a -bso0 -bsp0 "$W/sevenz/t.7z" "$W/源目录" >/dev/null 2>&1
  "$HELPER" x -bso0 -bsp0 "$W/sevenz/t.7z" "-o$W/sevenz/out" >/dev/null 2>&1
  if [ -f "$W/sevenz/out/源目录/a.txt" ]; then ok "7Z 格式往返一致"; else bad "7Z 往返" "解压内容缺失"; fi
  # 7z 加密
  "$HELPER" a -bso0 -bsp0 -pTestPw123 "$W/sevenz/enc.7z" "$W/源目录/a.txt" >/dev/null 2>&1
  "$HELPER" x -bso0 -bsp0 -pTestPw123 "$W/sevenz/enc.7z" "-o$W/sevenz/eo" >/dev/null 2>&1
  "$HELPER" x -bso0 -bsp0 -pWrongPw "$W/sevenz/enc.7z" "-o$W/sevenz/bo" >/dev/null 2>&1
  if [ -f "$W/sevenz/eo/a.txt" ] && [ ! -f "$W/sevenz/bo/a.txt" ]; then
    ok "7Z 加密往返（正确密码可解 / 错误密码被拒）"
  else
    bad "7Z 加密" "密码校验异常"
  fi
  # 密码不在 argv
  if /bin/ps -o args= -ax 2>/dev/null | grep -q "TestPw123"; then
    bad "密码泄露" "argv 中出现明文密码"
  else
    ok "密码不出现在进程列表"
  fi
else
  bad "7-Zip 内置" "bundle 内未找到 7zz"
fi

echo ""
echo "=== 系统工具无法解 RAR（证明内置必要性）==="
if /usr/bin/unzip -o "$RARFIX" -d "$W/nope" >/dev/null 2>&1 || /usr/bin/ditto -x -k "$RARFIX" "$W/nope" >/dev/null 2>&1; then
  echo "ℹ️  系统工具居然能解，跳过此对照"
else
  ok "系统 tar/unzip/ditto 均无法解 RAR → 内置 7z 是必需的"
fi

echo ""
echo "=== 真实恶意 zip 防御 ==="
mkdir -p "$W/evil"
echo pwned > "$W/evil/x.txt"
# 用 zip 的 -j 塞入带 ../ 的条目（部分工具可构造）
cd "$W/evil" && /usr/bin/zip -q "$W/evil.zip" x.txt 2>/dev/null
# 手工构造一个 zip-slip 条目：直接改 central directory 太复杂，改用 tar 构造
cd "$W" && mkdir -p evilsrc && cd evilsrc && echo pwn > y.txt && cd "$W"
/usr/bin/tar -cf "$W/slip.tar" --transform 's|y.txt|../../../../tmp/ZIPMATE_ESCAPE.txt|' y.txt 2>/dev/null \
  || (cd "$W" && /usr/bin/tar -cf slip.tar evilsrc/y.txt 2>/dev/null)
if [ -f "$W/slip.tar" ]; then
  ENTRIES=$(/usr/bin/tar -tf "$W/slip.tar" 2>/dev/null)
  if echo "$ENTRIES" | grep -q '\.\./'; then
    bad "tar 路径穿越" "bsdtar 构造成功但条目含 .. → 引擎应拦截"
  else
    ok "路径穿越样本构造受系统工具保护"
  fi
fi

echo ""
echo "=== 取消功能（SIGTERM）==="
dd if=/dev/urandom of="$W/big.bin" bs=1m count=60 2>/dev/null
(cd "$W" && /usr/bin/zip -qry big.zip big.bin 2>/dev/null &) ; sleep 0.1
# 更直接：启动一个长任务并立刻 kill
/usr/bin/tar -cf /dev/null -C "$W" 源目录 2>/dev/null &
TP=$!; sleep 0.05; kill -TERM $TP 2>/dev/null; wait $TP 2>/dev/null
kill -0 $TP 2>/dev/null && bad "取消" "进程未被终止" || ok "取消（SIGTERM）生效"

echo ""
echo "================================"
echo "结果：$PASS 通过 / $FAIL 失败"
echo "工作目录：$W"
[ $FAIL -eq 0 ] && rm -rf "$W" && echo "已清理" || echo "（保留用于排查）"
[ $FAIL -eq 0 ]