import json
import os
import boto3

# Trigger Lambda.
# EventBridge invokes this whenever an image is pushed to ECR. It works out the
# image reference and asks the orchestrator Lambda (run-registry-scan) to scan it.

lambda_client = boto3.client('lambda')

SCANNER_LAMBDA_NAME = os.environ.get('SCANNER_LAMBDA_NAME', 'run-registry-scan')
ECS_CLUSTER = os.environ.get('ECS_CLUSTER', 'Sysdig-Fargate-Test-Cluster')
# No revision -> the scanner uses the latest ACTIVE revision of the family.
ECS_TASK_DEFINITION = os.environ.get('ECS_TASK_DEFINITION', 'Sysdig-Registry-Scanner')
SUBNET_ID = os.environ.get('SUBNET_ID', '')
SECURITY_GROUP_ID = os.environ.get('SECURITY_GROUP_ID', '')


def lambda_handler(event, context):
    print(f'ECR push event: {json.dumps(event)}')
    try:
        detail = event['detail']
        repository = detail['repository-name']
        tag = detail.get('image-tag', 'latest')
        account_id = event['account']
        region = event['region']

        image_to_scan = f'{repository}:{tag}'
        registry_url = f'{account_id}.dkr.ecr.{region}.amazonaws.com'

        payload = {
            'image_to_scan': image_to_scan,
            'registry_url': registry_url,
            'cluster': ECS_CLUSTER,
            'task_definition': ECS_TASK_DEFINITION,
            'subnet': SUBNET_ID,
            'security_groups': [SECURITY_GROUP_ID],
        }
        print(f'Invoking {SCANNER_LAMBDA_NAME} for {image_to_scan}')

        # Fire and forget - the scanner Lambda does the waiting.
        lambda_client.invoke(
            FunctionName=SCANNER_LAMBDA_NAME,
            InvocationType='Event',
            Payload=json.dumps(payload),
        )
        return {'statusCode': 200, 'body': json.dumps({'message': f'Scan requested for {image_to_scan}'})}

    except KeyError as e:
        print(f'Unexpected event structure, missing {e}')
        return {'statusCode': 400, 'body': json.dumps({'error': f'Invalid event: missing {e}'})}
    except Exception as e:
        print(f'Error: {e}')
        return {'statusCode': 500, 'body': json.dumps({'error': str(e)})}
