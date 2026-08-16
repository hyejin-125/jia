import json
import boto3

# DynamoDB 리소스 설정
dynamodb = boto3.resource('dynamodb', region_name='ap-northeast-2')
table = dynamodb.Table('wskorea26-data-table')

def lambda_handler(event, context):
    query_params = event.get('queryStringParameters') or {}
    concert_name = query_params.get('concert_name')
    
    if not concert_name:
        return create_alb_response(400, {"message": "Bad Request: concert_name is required"})
    
    target_name = concert_name.strip()
    
    try:
        response = table.scan()
        all_items = response.get('Items', [])
        
        filtered_items = []
        for item in all_items:
            db_concert_name = item.get('concert_name')
            
            if db_concert_name is not None:
                if str(db_concert_name).strip() == target_name:
                    filtered_items = filtered_items + [item]
        
        if filtered_items:
            filtered_items.sort(key=lambda x: x.get('created_at', ''), reverse=True)
        
        return create_alb_response(200, filtered_items)
        
    except Exception as e:
        print(f"Error scanning DynamoDB: {str(e)}")
        return create_alb_response(500, {"message": "Internal Server Error"})

def create_alb_response(status_code, body_data):
    return {
        "isBase64Encoded": False,
        "statusCode": status_code,
        "statusDescription": f"{status_code} OK" if status_code == 200 else f"{status_code} Error",
        "headers": {
            "Content-Type": "application/json; charset=utf-8"
        },
        "body": json.dumps(body_data, ensure_ascii=False)
    }