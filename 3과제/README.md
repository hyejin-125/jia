# aws 3과제
전국기능경기대회 제61회 클라우드 컴퓨팅


## 구성요소

## 🛠️ 시스템 아키텍처 및 인프라 체크리스트

### 📍 기본 인프라 (Region & Compute)
- [ ] **Region**: `ap-northeast-2` (서울 리전)
- [ ] **EKS Cluster**: Amazon EKS 기반 컨테이너 오케스트레이션
- [ ] **EC2 Node**: `t3.medium` 1대 구성
- [ ] **최적화**: 불필요한 EC2 추가 생성 없음 (비용 및 자원 관리)

### 📦 컨테이너 및 데이터 베이스 (Registry & Data)
- [ ] **ECR**: Amazon Elastic Container Registry 이미지 저장소 사용
- [ ] **RDS**: Amazon RDS 구축
  - [ ] **Engine**: `MySQL 8.0`
  - [ ] **Instance Class**: `db.t3.micro`
  - [ ] **Storage**: `gp3`
  - [ ] **Deployment**: `Multi-AZ` (고가용성 다중 AZ 구성)
- [ ] **S3**: Amazon S3 정적 객체 스토리지 활용

### 🌐 네트워크 및 라우팅 (ALB & Ingress)
- [ ] **외부 엔드포인트**: 단일 `ALB` (AWS Application Load Balancer) 구성
- [ ] **API 라우팅 규칙**:
  - [ ] `/v1/user`
  - [ ] `/v1/product`
  - [ ] `/v1/stress`
  - [ ] `/images/*`

### ⚙️ 운영 및 모니터링 (Ops & Scaling)
- [ ] **Health Check**: 애플리케이션 및 타겟 그룹 헬스 체크 적용
- [ ] **HPA**: Horizontal Pod Autoscaler (파드 자동 수평 확장) 설정
- [ ] **예외 처리**: 비정상 요청에 대한 `403` / `404` 응답 처리
- [ ] **모니터링**: `CloudWatch` 연동을 통한 실시간 지표 관측


## cloudshll
01_infra.sh 실행

ECR 이미지 생성


네가 받은 실제 파일

user
product
stress
