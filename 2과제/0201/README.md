## Region
- 싱가포르/ap-southeast-1

<br>

## 환경변수
```bash
export CANDIDATE_NUMBER=<비번호>
```

<br>

## template
배포파일/test.csv
```bash
wget https://raw.githubusercontent.com/zjarhkrh/skills/refs/heads/main/2%EA%B3%BC%EC%A0%9C/0201/stepfunction_app.py
wget https://raw.githubusercontent.com/zjarhkrh/skills/refs/heads/main/2%EA%B3%BC%EC%A0%9C/0201/stepfunction_trigger.py
wget https://raw.githubusercontent.com/zjarhkrh/skills/refs/heads/main/2%EA%B3%BC%EC%A0%9C/0201/workflow.py
```

<br>

## python
```bash
sudo dnf install -y python3-pip
python3 -m pip install --user boto3
```
```bash
python3 ./workflow.py
```
