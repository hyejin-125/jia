## Region
- 서울/ap-northeast-2

<br>

## shell
```bash
wget https://raw.githubusercontent.com/zjarhkrh/skills/refs/heads/main/2과제/0202/01-vpc.sh
wget https://raw.githubusercontent.com/zjarhkrh/skills/refs/heads/main/2과제/0202/02-kinesis.sh
```

<br>

## Studio 노트북
- name: wsc2026-analytics-flink
- IAM: wsc2026-analytics-flink-role
- GlueDB: wsc2026_db
- 병렬 처리: 4
- KPU당 병렬 처리: 4
- VPC X

<br>

## Zeppelin
```bash
%flink.ssql

CREATE TABLE order_stream (
    product_name STRING,
    price DOUBLE,
    quantity INT,
    event_time TIMESTAMP(3),
    WATERMARK FOR event_time AS event_time - INTERVAL '3' SECOND 
) WITH (
    'connector' = 'kinesis',
    'stream' = 'wsc2026-order-stream',
    'aws.region' = 'ap-northeast-2',
    'scan.stream.init-position' = 'LATEST',
    'format' = 'json'
);
```
```bash
%flink.ssql

SELECT COUNT(*) as order_count
FROM order_stream
WHERE event_time > LOCALTIMESTAMP - INTERVAL '1' MINUTE;
```
```bash
%flink.ssql

SELECT product_name, SUM(price * quantity) as total_revenue 
FROM order_stream 
GROUP BY product_name;
```

<br>

## shell
- Zepplin 중지
```bash
wget https://raw.githubusercontent.com/zjarhkrh/skills/refs/heads/main/2과제/0202/03-ec2.sh
```
