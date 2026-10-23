"""Supabase 규칙(RLS) 시험. 공개 키(anon)만 쓰고 비밀 키는 쓰지 않는다.

사용 순서
  1) python rls_test.py setup    시험용 계정 3개를 가입시키고, 대시보드 SQL Editor에서 실행할 SQL을 출력한다.
  2) (출력된 SQL 실행)
  3) python rls_test.py run      허용/거부가 의도대로인지 확인한다.
  4) python rls_test.py cleanup  시험 데이터 삭제용 SQL을 출력한다(SQL Editor에서 실행).
시험용 계정은 rlstest-*@mailinator.com 이다. 가입 인증 메일을 끈(Confirm email 해제) 상태에서만 동작한다.
"""
import json
import os
import random
import string
import sys
import time

import requests

HERE = os.path.dirname(os.path.abspath(__file__))
CFG = open(os.path.join(HERE, "..", "config.js"), encoding="utf-8").read()


def cfg(name):
    return CFG.split(name + ':')[1].split('"')[1]


URL, ANON = cfg("SUPABASE_URL"), cfg("SUPABASE_ANON_KEY")
USERS_FILE = os.path.join(HERE, ".rls_users.json")
H = {"apikey": ANON, "Content-Type": "application/json"}


def hdr(token=None, extra=None):
    h = dict(H)
    h["Authorization"] = "Bearer " + (token or ANON)
    h.update(extra or {})
    return h


def signup(label):
    rnd = "".join(random.choices(string.ascii_lowercase + string.digits, k=8))
    email, pw = f"rlstest-{label}-{rnd}@mailinator.com", "Pw!" + "".join(random.choices(string.ascii_letters + string.digits, k=12))
    r = requests.post(f"{URL}/auth/v1/signup", headers=H, json={"email": email, "password": pw, "data": {"name": f"시험{label}"}}, timeout=30)
    d = r.json()
    if r.status_code != 200 or "access_token" not in d:
        sys.exit(f"가입 실패({label}): {r.status_code} {str(d)[:200]}\n-> Authentication > Providers > Email 에서 'Confirm email'을 끄세요.")
    return {"email": email, "password": pw, "id": d["user"]["id"], "name": f"시험{label}"}


def login(u):
    r = requests.post(f"{URL}/auth/v1/token?grant_type=password", headers=H, json={"email": u["email"], "password": u["password"]}, timeout=30)
    return r.json()["access_token"]


def setup():
    users = {k: signup(k) for k in ("admin", "user", "other")}
    json.dump(users, open(USERS_FILE, "w", encoding="utf-8"))
    print("시험용 계정 3개 가입 완료. 아래 SQL을 대시보드 SQL Editor에서 실행하세요.\n")
    a = users["admin"]["email"]
    print(f"insert into public.admins (user_id) select id from auth.users where email = '{a}' on conflict do nothing;")
    print(f"update public.profiles set status = 'approved' where email = '{a}';")


class T:
    ok = bad = 0

    @classmethod
    def check(cls, name, cond, detail=""):
        cls.ok += bool(cond)
        cls.bad += not cond
        print(("통과  " if cond else "실패  ") + name + ("" if cond else f"  <- {detail}"))


def denied(r):
    """거부로 본다: 4xx 이거나, 200/201인데 영향받은 행이 없음"""
    if r.status_code >= 400:
        return True
    try:
        return r.json() == [] or r.json() is None
    except Exception:
        return False


def run():
    if not os.path.exists(USERS_FILE):
        sys.exit("먼저 setup 을 실행하세요")
    U = json.load(open(USERS_FILE, encoding="utf-8"))
    ta, tu, to = login(U["admin"]), login(U["user"]), login(U["other"])
    rest = lambda path: f"{URL}/rest/v1/{path}"
    prefer = {"Prefer": "return=representation"}

    print("== 로그인 없는 방문자")
    T.check("댓글 읽기 가능", requests.get(rest("comments?select=id"), headers=hdr()).status_code == 200)
    r = requests.post(rest("comments"), headers=hdr(extra=prefer), json={"place_no": "1", "body": "x", "user_id": U["user"]["id"]})
    T.check("댓글 쓰기 거부", denied(r), r.text[:120])
    T.check("프로필 목록은 비어 보임", requests.get(rest("profiles?select=*"), headers=hdr()).json() == [])
    T.check("관리자 목록은 비어 보임", requests.get(rest("admins?select=*"), headers=hdr()).json() == [])

    print("== 가입만 한 사람(승인 대기)")
    r = requests.post(rest("comments"), headers=hdr(tu, prefer), json={"place_no": "1", "body": "대기자 댓글"})
    T.check("댓글 쓰기 거부", denied(r), r.text[:120])
    r = requests.post(rest("suggestions"), headers=hdr(tu, prefer), json={"ko": "대기자 제안"})
    T.check("제안 쓰기 거부", denied(r), r.text[:120])
    r = requests.patch(rest(f"profiles?user_id=eq.{U['user']['id']}"), headers=hdr(tu, prefer), json={"status": "approved"})
    T.check("스스로 승인 거부", denied(r), r.text[:120])
    r = requests.post(f"{URL}/rest/v1/rpc/grant_admin", headers=hdr(tu), json={"target": U["user"]["id"]})
    T.check("스스로 관리자 지정 거부", r.status_code >= 400, r.text[:120])
    r = requests.post(f"{URL}/storage/v1/object/photos/{U['user']['id']}/t.webp", headers={"apikey": ANON, "Authorization": "Bearer " + tu, "Content-Type": "image/webp"}, data=b"RIFF0000WEBP")
    T.check("사진 올리기 거부", r.status_code >= 400, r.text[:120])

    print("== 관리자")
    T.check("is_admin 참", requests.post(f"{URL}/rest/v1/rpc/is_admin", headers=hdr(ta), json={}).json() is True,
            "setup 이 출력한 SQL을 실행했나요?")
    pr = requests.get(rest("profiles?select=email,status"), headers=hdr(ta)).json()
    T.check("관리자는 모든 프로필을 봄", isinstance(pr, list) and len(pr) >= 3, str(pr)[:100])
    r = requests.patch(rest(f"profiles?user_id=eq.{U['user']['id']}"), headers=hdr(ta, prefer), json={"status": "approved"})
    T.check("관리자가 승인", r.status_code == 200 and r.json() and r.json()[0]["status"] == "approved", r.text[:120])

    print("== 승인된 사람")
    uid, oid = U["user"]["id"], U["other"]["id"]
    r = requests.post(rest("comments"), headers=hdr(tu, prefer), json={"place_no": "1", "body": "승인된 사람 댓글"})
    ok = r.status_code in (200, 201) and r.json()
    T.check("댓글 쓰기 허용", ok, r.text[:120])
    cid = r.json()[0]["id"] if ok else None
    T.check("작성자 이름은 서버가 채움", ok and r.json()[0]["author_name"] == U["user"]["name"], r.text[:160])
    r = requests.post(rest("comments"), headers=hdr(tu, prefer), json={"place_no": "1", "body": "남의 이름", "user_id": oid})
    T.check("다른 사람 이름으로 쓰기 거부", denied(r), r.text[:120])
    r = requests.post(rest("comments"), headers=hdr(tu, prefer), json={"place_no": "1", "body": "숨김", "hidden": True})
    T.check("숨김 상태로 쓰기 거부", denied(r), r.text[:120])
    r = requests.post(rest("comments"), headers=hdr(tu, prefer), json={"place_no": "1", "body": "x" * 1001})
    T.check("1000자 초과 거부", denied(r), r.text[:120])
    r = requests.post(rest("suggestions"), headers=hdr(tu, prefer), json={"ko": "시험 가게", "note": "메모"})
    sok = r.status_code in (200, 201) and r.json()
    T.check("제안 쓰기 허용(대기)", sok and r.json()[0]["status"] == "pending", r.text[:120])
    sid = r.json()[0]["id"] if sok else None
    r = requests.post(rest("suggestions"), headers=hdr(tu, prefer), json={"ko": "스스로 승인", "status": "approved"})
    T.check("승인 상태로 제안 쓰기 거부", denied(r), r.text[:120])
    T.check("대기 중 제안은 방문자에게 안 보임", requests.get(rest(f"suggestions?id=eq.{sid}&select=id"), headers=hdr()).json() == [])
    T.check("대기 중 제안은 본인에게 보임", len(requests.get(rest(f"suggestions?id=eq.{sid}&select=id"), headers=hdr(tu)).json()) == 1)
    r = requests.patch(rest(f"suggestions?id=eq.{sid}"), headers=hdr(tu, prefer), json={"status": "approved"})
    row = r.json()[0] if r.status_code == 200 and r.json() else {}
    T.check("본인이 제안 상태를 승인으로 바꿀 수 없음", denied(r) or row.get("status") == "pending", r.text[:120])

    print("== 본인 글 수정")
    requests.patch(rest(f"profiles?user_id=eq.{oid}"), headers=hdr(ta, prefer), json={"status": "approved"})  # 다른 사람도 승인해 둔다
    if cid:
        r = requests.patch(rest(f"comments?id=eq.{cid}"), headers=hdr(tu, prefer), json={"body": "수정한 댓글", "hidden": True, "place_no": "99", "author_name": "위조"})
        row = r.json()[0] if r.status_code == 200 and r.json() else {}
        T.check("본인 댓글 내용 수정", row.get("body") == "수정한 댓글", r.text[:160])
        T.check("수정 시각이 기록됨", bool(row.get("updated_at")), r.text[:160])
        T.check("숨김·가게·작성자 이름은 바꿀 수 없음", row.get("hidden") is False and row.get("place_no") == "1" and row.get("author_name") == U["user"]["name"], r.text[:200])
        r = requests.patch(rest(f"comments?id=eq.{cid}"), headers=hdr(to, prefer), json={"body": "남이 수정"})
        T.check("승인된 다른 사람은 남의 댓글을 못 고침", denied(r), r.text[:120])
        r = requests.patch(rest(f"comments?id=eq.{cid}"), headers=hdr(extra=prefer), json={"body": "방문자 수정"})
        now = requests.get(rest(f"comments?id=eq.{cid}&select=body"), headers=hdr()).json()
        T.check("방문자는 댓글을 못 고침", denied(r) and now and now[0]["body"] == "수정한 댓글", r.text[:120])
    if sid:
        r = requests.patch(rest(f"suggestions?id=eq.{sid}"), headers=hdr(tu, prefer), json={"ko": "수정한 가게", "note": "수정 메모", "photos": ["https://example.com/a.webp"], "status": "approved", "admin_note": "위조"})
        row = r.json()[0] if r.status_code == 200 and r.json() else {}
        T.check("본인 제안 내용·사진 수정", row.get("ko") == "수정한 가게" and row.get("photos") == ["https://example.com/a.webp"], r.text[:200])
        T.check("제안의 상태·관리자 메모는 바꿀 수 없음", row.get("status") == "pending" and row.get("admin_note") == "", r.text[:200])
        r = requests.patch(rest(f"suggestions?id=eq.{sid}"), headers=hdr(to, prefer), json={"ko": "남이 수정"})
        T.check("승인된 다른 사람은 남의 제안을 못 고침", denied(r), r.text[:120])
        r = requests.delete(rest(f"suggestions?id=eq.{sid}"), headers=hdr(to, prefer))
        T.check("승인된 다른 사람은 남의 제안을 못 지움", denied(r), r.text[:120])

    print("== 사진 저장소")
    sp = {"apikey": ANON, "Authorization": "Bearer " + tu}
    tiny = b"RIFF\x1a\x00\x00\x00WEBPVP8L\x0d\x00\x00\x00/\x00\x00\x00\x10\x07\x10\x11\x11\x88\x88\xfe\x07\x00"
    path = f"{uid}/{int(time.time())}.webp"
    r = requests.post(f"{URL}/storage/v1/object/photos/{path}", headers={**sp, "Content-Type": "image/webp"}, data=tiny)
    T.check("자기 폴더에 올리기 허용", r.status_code in (200, 201), r.text[:120])
    r = requests.post(f"{URL}/storage/v1/object/photos/{oid}/x.webp", headers={**sp, "Content-Type": "image/webp"}, data=tiny)
    T.check("남의 폴더에 올리기 거부", r.status_code >= 400, r.text[:120])
    r = requests.post(f"{URL}/storage/v1/object/photos/{uid}/big.webp", headers={**sp, "Content-Type": "image/webp"}, data=b"0" * 600000)
    T.check("500KB 초과 거부", r.status_code >= 400, r.text[:120])
    r = requests.post(f"{URL}/storage/v1/object/photos/{uid}/a.png", headers={**sp, "Content-Type": "image/png"}, data=tiny)
    T.check("png 형식 거부", r.status_code >= 400, r.text[:120])
    T.check("올린 사진은 로그인 없이 볼 수 있음", requests.get(f"{URL}/storage/v1/object/public/photos/{path}").status_code == 200)
    requests.delete(f"{URL}/storage/v1/object/photos/{path}", headers=sp)

    print("== 다른 사람(승인 대기) 과 관리자의 댓글 관리")
    if cid:
        r = requests.delete(rest(f"comments?id=eq.{cid}"), headers=hdr(to, prefer))
        T.check("남의 댓글 삭제 거부", denied(r), r.text[:120])
        r = requests.patch(rest(f"comments?id=eq.{cid}"), headers=hdr(tu, prefer), json={"hidden": True})
        row = r.json()[0] if r.status_code == 200 and r.json() else {}
        T.check("본인이 댓글을 숨길 수 없음", denied(r) or row.get("hidden") is False, r.text[:120])
        r = requests.patch(rest(f"comments?id=eq.{cid}"), headers=hdr(ta, prefer), json={"hidden": True})
        T.check("관리자가 댓글 숨기기", r.status_code == 200 and r.json(), r.text[:120])
        T.check("숨긴 댓글은 방문자에게 안 보임", requests.get(rest(f"comments?id=eq.{cid}&select=id"), headers=hdr()).json() == [])
    if sid:
        r = requests.patch(rest(f"suggestions?id=eq.{sid}"), headers=hdr(ta, prefer), json={"status": "approved"})
        T.check("관리자가 제안 승인", r.status_code == 200 and r.json(), r.text[:120])
        T.check("승인된 제안은 방문자에게 보임", len(requests.get(rest(f"suggestions?id=eq.{sid}&select=id"), headers=hdr()).json()) == 1)

    if sid:
        r = requests.delete(rest(f"suggestions?id=eq.{sid}"), headers=hdr(tu, prefer))
        T.check("본인은 승인된 제안도 삭제할 수 있음", r.status_code == 200 and bool(r.json()), r.text[:120])

    print("== 관리자 인수인계")
    ids = {x["user_id"] for x in requests.get(rest("admins?select=user_id"), headers=hdr(ta)).json()}
    real = ids - {U["admin"]["id"], uid, oid}      # 시험 계정이 아닌 실제 관리자
    r = requests.post(f"{URL}/rest/v1/rpc/grant_admin", headers=hdr(ta), json={"target": uid})
    T.check("다음 관리자 지정", r.status_code in (200, 204), r.text[:120])
    r = requests.post(f"{URL}/rest/v1/rpc/revoke_admin", headers=hdr(ta), json={"target": U["admin"]["id"]})
    T.check("지정 후에는 이전 관리자 해제 가능", r.status_code in (200, 204), r.text[:120])
    r = requests.post(f"{URL}/rest/v1/rpc/revoke_admin", headers=hdr(tu), json={"target": uid})
    if real:
        print("건너뜀  마지막 관리자 해제 거부 (실제 관리자가 따로 있어 이 시험은 할 수 없음. 시험 계정만 있던 첫 시험에서 통과 확인됨)")
        T.check("시험 관리자 해제(실제 관리자가 있으므로 허용)", r.status_code in (200, 204), r.text[:120])
    else:
        T.check("남은 마지막 관리자는 해제 거부", r.status_code >= 400, r.text[:120])

    print(f"\n통과 {T.ok} / 실패 {T.bad}")
    sys.exit(1 if T.bad else 0)


def cleanup():
    print("대시보드 SQL Editor에서 실행하세요(시험 계정과 그 댓글·제안·프로필이 함께 삭제됩니다):\n")
    print("delete from auth.users where email like 'rlstest-%@mailinator.com';")
    print("\n(사진은 시험 중에 이미 지웠습니다.)")


if __name__ == "__main__":
    {"setup": setup, "run": run, "cleanup": cleanup}.get(sys.argv[1] if len(sys.argv) > 1 else "", lambda: print(__doc__))()
