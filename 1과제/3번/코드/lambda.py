import os
import json
import boto3
from boto3.dynamodb.conditions import Attr
from base64 import b64decode
from collections import OrderedDict
from datetime import datetime

ENCRYPTED_TABLE_NAME = os.environ['TABLE_NAME']
TABLE_NAME = boto3.client('kms').decrypt(
    CiphertextBlob=b64decode(ENCRYPTED_TABLE_NAME),
    EncryptionContext={'LambdaFunctionName': os.environ['AWS_LAMBDA_FUNCTION_NAME']}
)['Plaintext'].decode('utf-8')

dynamodb = boto3.resource('dynamodb')
table = dynamodb.Table(TABLE_NAME)

def lambda_handler(event, context):
    try:
        # Query String에서 booking_id 추출
        query_params = event.get('queryStringParameters') or {}
        booking_id = query_params.get('booking_id')
        
        if not booking_id:
            return {
                'statusCode': 400,
                'body': json.dumps({'message': 'Missing booking_id parameter'})
            }
        
        # 수정: booking_id로 데이터를 찾기 위해 scan 및 FilterExpression 사용
        response = table.scan(
            FilterExpression=Attr('booking_id').eq(booking_id)
        )
        items = response.get('Items', [])
        item = items[0] if items else None
        
        if not item:
            return {
                'statusCode': 404,
                'body': json.dumps({'message': 'Booking not found'})
            }
            
        raw_created_at = item.get('created_at', '')
        formatted_created_at = raw_created_at
        
        try:
            if isinstance(raw_created_at, (int, float)): # 타임스탬프 숫자일 경우
                dt = datetime.fromtimestamp(raw_created_at)
                formatted_created_at = dt.strftime('%Y-%m-%d %H:%M:%S KST')
            elif isinstance(raw_created_at, str): # 문자열일 경우 파싱 시도
                if 'T' in raw_created_at:
                    dt = datetime.fromisoformat(raw_created_at.replace('Z', '+00:00'))
                    formatted_created_at = dt.strftime('%Y-%m-%d %H:%M:%S KST')
        except Exception:
            pass

        response_body = OrderedDict([
            ("client_id", item.get("client_id", "")),
            ("username", item.get("username", "")),
            ("email", item.get("email", "")),
            ("concert_name", item.get("concert_name", "")),
            ("created_at", formatted_created_at)
        ])
        
        return {
            'statusCode': 200,
            'headers': {
                'Content-Type': 'application/json'
            },
            'body': json.dumps(response_body, ensure_ascii=False)
        }
        
    except Exception as e:
        print(f"Error: {str(e)}")
        return {
            'statusCode': 500,
            'body': json.dumps({'message': 'Internal Server Error', 'error': str(e)})
        }