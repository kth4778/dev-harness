#!/usr/bin/env python3
"""감사 패널의 표를 **코드가** 센다. build 의 감사 라운드에서 부른다.

    "${CLAUDE_PLUGIN_ROOT}/skills/build/scripts/panel-tally.py" <표디렉터리> [--voters 3] [--keep 2]

왜 스크립트인가: 표를 모델이 세면 그것은 표가 아니라 또 하나의 의견이다.
"셋 중 둘이 인정했으니 채택"을 산문으로 쓰는 순간, 그 문장을 쓴 모델이
네 번째 투표자가 된다. 세는 일은 모델 밖에서 끝나야 한다.

표 하나는 JSON 파일 하나다.

    {"finding_id": "F1", "lens": "reachability",
     "verdict": "TRUE_POSITIVE", "evidence": "src/A.java:42"}

채택 조건은 넷이고, **하나라도 어긋나면 미채택**이다.

    1. 유효표 수가 기대 투표자 수와 정확히 같다
    2. 렌즈가 겹치지 않는다 — 같은 렌즈 둘은 독립된 표가 아니다
    3. 인정표가 임계 이상이다
    4. 모든 표에 증거가 있다 — 증거 없는 표는 무효라 1번에서 걸린다

**표가 모자랄 때 통과시키지 않는 것이 이 스크립트의 존재 이유다.** 투표자
하나가 죽거나 시간이 다 되어 안 돌아왔을 때 남은 둘로 채택하면, 패널을
셋으로 짠 이유가 사라진다. 모르면 미채택이다.
"""
import argparse
import json
import os
import sys
from collections import Counter

for _s in (sys.stdout, sys.stderr):
    try:
        _s.reconfigure(errors="replace")
    except AttributeError:
        pass

TRUE, FALSE = "TRUE_POSITIVE", "FALSE_POSITIVE"


def die(msg):
    print("집계 불가 — %s" % msg, file=sys.stderr)
    sys.exit(2)


def load(paths):
    """표 파일을 모은다. 하나라도 못 읽으면 죽는다 — 조용히 0표로 세지 않는다."""
    files = []
    for p in paths:
        if os.path.isdir(p):
            files += [os.path.join(p, f) for f in sorted(os.listdir(p))
                      if f.endswith(".json")]
        elif os.path.isfile(p):
            files.append(p)
        else:
            die("경로가 없다: %s" % p)
    if not files:
        die("표 파일이 하나도 없다 (%s)" % ", ".join(paths))

    votes = []
    for f in files:
        try:
            with open(f, encoding="utf-8") as fh:
                v = json.load(fh)
        except (OSError, ValueError) as e:
            die("%s 를 읽을 수 없다: %s" % (f, e))
        if not isinstance(v, dict):
            die("%s 가 표 객체가 아니다" % f)
        v["_file"] = os.path.basename(f)
        votes.append(v)
    return votes


def invalid_reason(v):
    """무효표면 사유를, 유효표면 None 을 준다."""
    if not v.get("finding_id"):
        return "finding_id 없음"
    if not v.get("lens"):
        return "lens 없음"
    if v.get("verdict") not in (TRUE, FALSE):
        return "모르는 판정값 %r" % v.get("verdict")
    if not str(v.get("evidence") or "").strip():
        return "증거 없음"
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("paths", nargs="+", help="표 JSON 이 든 디렉터리 또는 파일")
    ap.add_argument("--voters", type=int, default=3, help="기대 투표자 수 (기본 3)")
    ap.add_argument("--keep", type=int, default=2, help="채택에 필요한 인정표 (기본 2)")
    a = ap.parse_args()
    if a.keep > a.voters:
        die("--keep(%d) 이 --voters(%d) 보다 크다 — 어떤 발견도 채택될 수 없다"
            % (a.keep, a.voters))

    votes = load(a.paths)

    # 무효표는 어느 발견의 것인지 알 수 있을 때만 그 발견에 붙인다.
    findings = {}
    orphan = []
    for v in votes:
        why = invalid_reason(v)
        fid = v.get("finding_id")
        if not fid:
            orphan.append((v["_file"], why))
            continue
        findings.setdefault(fid, {"valid": [], "bad": []})
        (findings[fid]["bad"] if why else findings[fid]["valid"]).append(
            (v, why) if why else v)

    for f, why in orphan:
        print("무효표 %s — %s" % (f, why), file=sys.stderr)

    kept = dropped = 0
    for fid in sorted(findings):
        g = findings[fid]
        valid, bad = g["valid"], g["bad"]
        n = len(valid)
        true_n = sum(1 for v in valid if v["verdict"] == TRUE)
        lenses = [v["lens"] for v in valid]
        dup = [l for l, c in Counter(lenses).items() if c > 1]

        why = []
        if n != a.voters:
            why.append("유효표가 %d — 기대 %d" % (n, a.voters))
        if dup:
            why.append("렌즈가 겹친다: %s" % ", ".join(sorted(dup)))
        if true_n < a.keep:
            why.append("인정 %d — 임계 %d" % (true_n, a.keep))

        note = ""
        if bad:
            note = "  무효 %d(%s)" % (
                len(bad), "; ".join("%s: %s" % (v["_file"], r) for v, r in bad))

        if why:
            dropped += 1
            print("DROP  %s  유효 %d/%d  인정 %d  — %s%s"
                  % (fid, n, a.voters, true_n, " / ".join(why), note))
        else:
            kept += 1
            print("KEEP  %s  유효 %d/%d  인정 %d  렌즈 %s%s"
                  % (fid, n, a.voters, true_n, ", ".join(sorted(lenses)), note))

    print("\n──── 채택 %d / 미채택 %d ────" % (kept, dropped))
    return 0


if __name__ == "__main__":
    sys.exit(main())
