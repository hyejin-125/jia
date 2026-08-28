#!/usr/bin/env python3
import argparse
import copy
import json
import os
import sys
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, quote_plus, urlparse

import boto3
from pymongo import MongoClient, ASCENDING, DESCENDING

AWS_REGION = "ap-northeast-2"
SECRET_NAME = "skills-nosql-docdb-secret"
DATABASE_NAME = "skills_retail"
DOCDB_PORT = 27017
LISTEN_HOST = "0.0.0.0"
LISTEN_PORT = 8080
DATA_FILE = "/opt/skills-nosql/retail_dataset.json"
CA_FILE = "/opt/skills-nosql/global-bundle.pem"

EXPECTED_COUNTS = {"orders": 8, "products": 6, "sessions": 3}
DATE_FIELDS = {
    "orders": ["createdAt", "dueAt"],
    "products": ["updatedAt"],
    "sessions": ["lastSeen", "expiresAt"],
}


def parse_iso_datetime(value):
    if isinstance(value, datetime):
        return value
    if value is None:
        return None
    return datetime.fromisoformat(str(value).replace("Z", "+00:00"))


def json_default(value):
    if isinstance(value, datetime):
        return value.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")
    return str(value)


def response(handler, status, payload):
    body = json.dumps(payload, ensure_ascii=False, default=json_default).encode("utf-8")
    handler.send_response(status)
    handler.send_header("Content-Type", "application/json; charset=utf-8")
    handler.send_header("Content-Length", str(len(body)))
    handler.end_headers()
    handler.wfile.write(body)


def load_dataset():
    with open(DATA_FILE, "r", encoding="utf-8") as f:
        return json.load(f)


def convert_dataset(raw):
    data = copy.deepcopy(raw)
    for collection, fields in DATE_FIELDS.items():
        for item in data.get(collection, []):
            for field in fields:
                if field in item:
                    item[field] = parse_iso_datetime(item[field])
    return data


def get_secret():
    res = boto3.client("secretsmanager", region_name=AWS_REGION).get_secret_value(SecretId=SECRET_NAME)
    data = json.loads(res["SecretString"])
    username = data.get("username")
    password = data.get("password")
    host = data.get("host")
    if not username or not password or not host:
        raise RuntimeError("Secret must contain username, password, and host")
    return username, password, host


def mongo_client():
    username, password, host = get_secret()
    if "://" in host or ":" in host:
        raise RuntimeError("Secret host must be a DocumentDB cluster endpoint hostname without scheme or port")
    if not os.path.exists(CA_FILE):
        raise RuntimeError(f"DocumentDB CA bundle not found: {CA_FILE}")
    uri = (
        f"mongodb://{quote_plus(username)}:{quote_plus(password)}@{host}:{DOCDB_PORT}/"
        "?replicaSet=rs0&readPreference=secondaryPreferred&retryWrites=false"
    )
    return MongoClient(
        uri,
        tls=True,
        tlsCAFile=CA_FILE,
        serverSelectionTimeoutMS=8000,
        connectTimeoutMS=8000,
    )


def db():
    return mongo_client()[DATABASE_NAME]


def seed_data():
    database = db()
    data = convert_dataset(load_dataset())
    for collection in ("orders", "products", "sessions"):
        database[collection].delete_many({})
        if data.get(collection):
            database[collection].insert_many(data[collection])
    return counts(database)


def counts(database=None):
    database = database if database is not None else db()
    return {name: database[name].count_documents({}) for name in EXPECTED_COUNTS}


def date_field_types(database=None):
    database = database if database is not None else db()
    result = {}
    for collection, fields in DATE_FIELDS.items():
        sample = database[collection].find_one({}, {field: 1 for field in fields}) or {}
        result[collection] = {field: type(sample.get(field)).__name__ for field in fields}
    return result


def indexes(database=None):
    database = database if database is not None else db()
    return {name: list(database[name].list_indexes()) for name in EXPECTED_COUNTS}


def health():
    client = mongo_client()
    client.admin.command("ping")
    return {"status": "ok", "database": DATABASE_NAME, "port": DOCDB_PORT, "tls": True}


def order_by_id(order_id):
    return db().orders.find_one({"orderId": order_id}, {"_id": 0}) or {}


def customer_orders(customer_id):
    return list(db().orders.find({"customerId": customer_id}, {"_id": 0}).sort("createdAt", DESCENDING))


def pending_orders(from_value, to_value):
    query = {"status": "PENDING"}
    if from_value or to_value:
        query["dueAt"] = {}
        if from_value:
            query["dueAt"]["$gte"] = parse_iso_datetime(from_value)
        if to_value:
            query["dueAt"]["$lte"] = parse_iso_datetime(to_value)
    return list(db().orders.find(query, {"_id": 0}).sort("dueAt", ASCENDING))


def low_stock(warehouse_id):
    items = db().products.find({"warehouseId": warehouse_id}, {"_id": 0}).sort([("stock", ASCENDING), ("productId", ASCENDING)])
    return [item for item in items if item.get("stock", 0) <= item.get("reorderPoint", 0)]


def recent_sessions(customer_id):
    return list(db().sessions.find({"customerId": customer_id}, {"_id": 0}).sort("lastSeen", DESCENDING).limit(5))


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % args))

    def do_POST(self):
        try:
            path = urlparse(self.path).path
            if path == "/v1/admin/seed":
                response(self, 200, {"seeded": True, "counts": seed_data()})
            else:
                response(self, 404, {"error": "not found"})
        except Exception as exc:
            response(self, 500, {"error": str(exc)})

    def do_GET(self):
        try:
            parsed = urlparse(self.path)
            path = parsed.path
            query = parse_qs(parsed.query)
            if path == "/health":
                response(self, 200, health())
            elif path == "/v1/admin/summary":
                response(self, 200, {"database": DATABASE_NAME, "counts": counts(), "dateFieldTypes": date_field_types()})
            elif path == "/v1/admin/indexes":
                response(self, 200, {"indexes": indexes()})
            elif path.startswith("/v1/orders/") and path != "/v1/orders/pending":
                response(self, 200, {"order": order_by_id(path.rsplit("/", 1)[-1])})
            elif path.startswith("/v1/customers/") and path.endswith("/orders"):
                customer_id = path.split("/")[3]
                response(self, 200, {"customerId": customer_id, "items": customer_orders(customer_id)})
            elif path == "/v1/orders/pending":
                response(self, 200, {"items": pending_orders(query.get("from", [None])[0], query.get("to", [None])[0])})
            elif path == "/v1/products/low-stock":
                warehouse_id = query.get("warehouseId", [""])[0]
                response(self, 200, {"warehouseId": warehouse_id, "items": low_stock(warehouse_id)})
            elif path == "/v1/sessions/recent":
                customer_id = query.get("customerId", [""])[0]
                response(self, 200, {"customerId": customer_id, "items": recent_sessions(customer_id)})
            else:
                response(self, 404, {"error": "not found"})
        except Exception as exc:
            response(self, 500, {"error": str(exc)})


def main():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("health")
    sub.add_parser("seed")
    sub.add_parser("indexes")
    sub.add_parser("counts")
    sub.add_parser("validate")
    sub.add_parser("serve")
    args = parser.parse_args()

    if args.command == "health":
        print(json.dumps(health(), ensure_ascii=False))
    elif args.command == "seed":
        print(json.dumps({"counts": seed_data()}, ensure_ascii=False))
    elif args.command == "indexes":
        print(json.dumps({"indexes": indexes()}, ensure_ascii=False, default=json_default))
    elif args.command == "counts":
        print(json.dumps({"counts": counts(), "dateFieldTypes": date_field_types()}, ensure_ascii=False))
    elif args.command == "validate":
        payload = {
            "health": health(),
            "counts": counts(),
            "dateFieldTypes": date_field_types(),
            "indexes": indexes(),
            "order": order_by_id("O-1001"),
            "customerOrders": customer_orders("C001"),
            "pendingOrders": pending_orders("2026-06-01T00:00:00Z", "2026-06-08T00:00:00Z"),
            "lowStock": low_stock("W-A"),
        }
        print(json.dumps(payload, ensure_ascii=False, default=json_default))
    elif args.command == "serve":
        httpd = ThreadingHTTPServer((LISTEN_HOST, LISTEN_PORT), Handler)
        print(f"listening on {LISTEN_HOST}:{LISTEN_PORT}", flush=True)
        httpd.serve_forever()


if __name__ == "__main__":
    main()
