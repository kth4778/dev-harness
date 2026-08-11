#!/usr/bin/env bash
# 시험용 가짜 시크릿.
#
# **문자열을 쪼개 조립한다.** 통째로 적으면 이 파일 자체가 secret-guard 에
# 걸려 시험을 커밋할 수 없다. 2026-08-11에 실물로 막혔다 — 훅이 제 일을 한
# 것이라 예외를 두지 않고 시험 쪽을 고쳤다. 가드에 예외 경로를 뚫으면
# 그 경로가 곧 우회로가 된다.
AWS_FAKE="AKIA""1234567890ABCDEF"
ANT_FAKE="sk-ant-""api03-AAAAAAAAAAAAAAAAAAAAAA"
GH_FAKE="ghp_""aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
PEM_FAKE="-----BEGIN RSA PRIVATE ""KEY-----"
