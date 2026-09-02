import json
import os 
import time
import urllib.request
import boto3


#Inigialize AWS SDK client

dynamodb = boto3.resource('dynamodb')
sns = boto3.client('sns')

TABLE_NAME = os.environ.get('DYNAMODB_TABLE', 'UptimeMetrics')
SNS_TOPIC_ARN = os.environ.get('SNS_TOPIC_ARN')


# Endpoints to monitor

TARGET_URLS = [
    "https://httpbin.org/status/200",  # Always UP (Test)
    "https://aws.amazon.com"
]

def lambda_handler(event, context):
    table = dynamodb.Table(TABLE_NAME)
    results = []

    for url in TARGET_URLS:
        start_time = time.time()
        status_code = 500
        status = "DOWN"
        latency_ms = 0

        try:
            req = urllib.request.Request(url, headers={'User-Agent': 'AWS-Uptime-Monitor/1.0'})
            with urllib.request.urlopen(req, timeout=5) as response:
                status_code = response.getcode()
                latency_ms = round((time.time() - start_time) * 1000, 2)
                if status_code == 200:
                    status = "UP"
        except Exception as e:
            latency_ms = round((time.time() - start_time) * 1000, 2)
            status_code = 500
            status = "DOWN"

        item = {
            "site_url": url,
            "timestamp": str(int(time.time())),
            "status": status,
            "status_code": status_code,
            "latency_ms": str(latency_ms)
        }

        # Save check result to DynamoDB
        table.put_item(Item=item)
        results.append(item)
        
        # Trigger email alert if the site is down
        if status == "DOWN" and SNS_TOPIC_ARN:
            sns.publish(
                TopicArn=SNS_TOPIC_ARN,
                Subject=f"ALERT: Downtime Detected for {url}",
                Message=f"Endpoint: {url}\nStatus Code: {status_code}\nLatency: {latency_ms}ms\nTimestamp: {item['timestamp']}"
            )

    return {
        "statusCode": 200,
        "headers": {
            "Content-Type": "application/json",
            "Access-Control-Allow-Origin": "*"
        },
        "body": json.dumps(results)
    }
