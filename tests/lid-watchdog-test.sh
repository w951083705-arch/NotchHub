#!/bin/zsh
# 不用 root 测试合盖看门狗：抽出 src/Awake.swift 里的脚本，把 pmset / ioreg 换成假的，记录它们被如何调用。
cd "${0:A:h}/.."
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
cat > $T/pmset <<F
#!/bin/sh
if [ "\$1" = "-g" ]; then cat $T/batt; else echo "\$*" >> $T/log; fi
F
cat > $T/ioreg <<F
#!/bin/sh
cat $T/lid
F
chmod +x $T/pmset $T/ioreg
sed -n '/static let watchdog = """/,/^    """/p' src/Awake.swift | sed '1d;$d;s/^    //' \
  | sed "s#/usr/bin/pmset#$T/pmset#g; s#/usr/sbin/ioreg#$T/ioreg#g" > $T/wd.sh
sh -n $T/wd.sh || { echo 语法错误; exit 1; }
AC="Now drawing from 'AC Power'
 -InternalBattery-0 (id=1)	100%; charged; 0:00 remaining present: true"
BAT="Now drawing from 'Battery Power'
 -InternalBattery-0 (id=1)	60%; discharging; 3:00 remaining present: true"
LOWBAT="Now drawing from 'Battery Power'
 -InternalBattery-0 (id=1)	15%; discharging; 0:30 remaining present: true"
WEAK="Now drawing from 'AC Power'
 -InternalBattery-0 (id=1)	12%; AC attached; not charging present: true"
CHG="Now drawing from 'AC Power'
 -InternalBattery-0 (id=1)	12%; charging; 2:00 remaining present: true"
OPEN='"AppleClamshellState" = No'; SHUT='"AppleClamshellState" = Yes'
F=$T/ctl; fail=0
setb() { print -r -- "$1" > $T/batt; }
check() { # 期望的 pmset 调用序列
  local got=$(tr '\n' '|' < $T/log 2>/dev/null)
  if [[ "$got" == "$2" ]]; then echo "通过 $1: $got"; else echo "失败 $1: 期望 [$2] 实际 [$got]"; fail=1; fi
}
begin() { : > $T/log; print -r -- "$OPEN" > $T/lid; echo "${1:-0}" > $F; sleep 300 & P=$!; sh $T/wd.sh $F $P & W=$!; sleep 1; }
finish() { rm -f $F; for i in {1..5}; do kill -0 $W 2>/dev/null || break; sleep 1; done; kill $P 2>/dev/null; wait $P 2>/dev/null; }

setb "$AC"; begin; finish; check "接电开启后关闭开关" "-a disablesleep 1|-a disablesleep 0|"
setb "$AC"; begin; setb "$BAT"; sleep 4; setb "$AC"; sleep 4; finish
check "拔电暂停、接电恢复（不重新授权）" "-a disablesleep 1|-a disablesleep 0|-a disablesleep 1|-a disablesleep 0|"
setb "$AC"; begin; print -r -- "$SHUT" > $T/lid; setb "$BAT"; sleep 4; check "合盖时拔电立刻睡眠" "-a disablesleep 1|-a disablesleep 0|sleepnow|"; print -r -- "$OPEN" > $T/lid; finish
setb "$BAT"; begin $(( $(date +%s) + 100 )); finish; check "电池 + 定时内生效" "-a disablesleep 1|-a disablesleep 0|"
setb "$BAT"; begin $(( $(date +%s) + 2 )); sleep 4; check "电池 + 定时到期暂停" "-a disablesleep 1|-a disablesleep 0|"; finish
setb "$LOWBAT"; begin $(( $(date +%s) + 100 )); check "定时内电量 15% 不生效" "-a disablesleep 0|"; finish
setb "$WEAK"; begin; check "接电但未充电且低电量不生效" "-a disablesleep 0|"; finish
setb "$CHG"; begin; check "低电量但在充电生效" "-a disablesleep 1|"; finish
setb "$AC"; begin; kill $P; wait $P 2>/dev/null; sleep 4; check "应用崩溃后恢复" "-a disablesleep 1|-a disablesleep 0|"; finish
setb "$AC"; begin; kill -TERM $W; sleep 1; check "看门狗收到 TERM 恢复" "-a disablesleep 1|-a disablesleep 0|"; finish
exit $fail
