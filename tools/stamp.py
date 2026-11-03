"""배포 버전 표시를 새로 찍는다. index.html의 BUILD 값과 version.json을 같은 새 값으로 바꾼다.
사이트가 열릴 때 version.json(캐시 없이 받음)과 자기 BUILD를 비교해, 다르면 새 버전으로 한 번 다시 불러온다.
코드(index.html 등)를 고쳐 올릴 때마다 커밋 전에 한 번 실행하세요:  python tools/stamp.py
(data/ 안의 글·사진만 고칠 때는 필요 없습니다. 데이터는 항상 새로 받습니다.)"""
import json
import os
import re
import time

root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
v = time.strftime("%Y%m%d-%H%M%S")
p = os.path.join(root, "index.html")
s = open(p, encoding="utf-8").read()
s2 = re.sub(r'const BUILD = "[^"]*";', f'const BUILD = "{v}";', s, count=1)
assert s2 != s or f'"{v}"' in s, "index.html에서 BUILD 줄을 찾지 못했습니다"
open(p, "w", encoding="utf-8").write(s2)
json.dump({"v": v}, open(os.path.join(root, "version.json"), "w"), ensure_ascii=False)
print("배포 버전:", v)
