import json
import base64
import boto3

# Orchestrator Lambda.
# Generates a short-lived ECR token, launches the Sysdig scanner as a one-shot
# Fargate task, waits for it to finish, and reports the result.

ecr = boto3.client('ecr')
ecs = boto3.client('ecs')


def lambda_handler(event, context):
    try:
        # The trigger Lambda invokes us with a plain dict. API Gateway would
        # wrap the payload in a JSON string under 'body'; handle both.
        body = json.loads(event['body']) if isinstance(event.get('body'), str) else event

        image_to_scan = body.get('image_to_scan')
        if not image_to_scan:
            return _response(400, {'error': 'image_to_scan is required'})

        registry_url = body.get('registry_url')
        cluster = body.get('cluster', 'Sysdig-Fargate-Test-Cluster')
        # No revision -> ECS uses the latest ACTIVE revision of the family.
        task_definition = body.get('task_definition', 'Sysdig-Registry-Scanner')

        # Accept subnets/security_groups as a single string or a list.
        subnets = _as_list(body.get('subnets', body.get('subnet')))
        security_groups = _as_list(body.get('security_groups'))
        if not subnets:
            return _response(400, {'error': 'subnet (or subnets) is required'})

        # 1. Get an ECR auth token using this Lambda's role.
        token = ecr.get_authorization_token()['authorizationData'][0]['authorizationToken']
        username, password = base64.b64decode(token).decode('utf-8').split(':')
        print('Got ECR token')

        full_image = f'{registry_url}/{image_to_scan}' if registry_url else image_to_scan
        print(f'Launching scan task for {full_image} on cluster {cluster}')

        # 2. Launch the scanner as a one-shot Fargate task. The ECR credentials
        #    and the single image to scan are passed as environment overrides.
        run = ecs.run_task(
            cluster=cluster,
            taskDefinition=task_definition,
            launchType='FARGATE',
            networkConfiguration={
                'awsvpcConfiguration': {
                    'subnets': subnets,
                    'securityGroups': security_groups,
                    'assignPublicIp': 'ENABLED',
                }
            },
            overrides={
                'containerOverrides': [{
                    'name': 'registry-scanner',
                    'environment': [
                        {'name': 'REGISTRYSCANNER_REGISTRY_USER', 'value': username},
                        {'name': 'REGISTRYSCANNER_REGISTRY_PASSWORD', 'value': password},
                        {'name': 'REGISTRYSCANNER_FILTER_IMAGELIST', 'value': image_to_scan},
                    ],
                }]
            },
        )
        task_arn = run['tasks'][0]['taskArn']
        task_id = task_arn.split('/')[-1]
        print(f'Task launched: {task_id}')

        # 3. Wait for the task to stop (up to 15 minutes).
        try:
            ecs.get_waiter('tasks_stopped').wait(
                cluster=cluster,
                tasks=[task_arn],
                WaiterConfig={'Delay': 10, 'MaxAttempts': 90},
            )
        except Exception as wait_error:
            print(f'Timed out waiting for task: {wait_error}')
            return _response(202, {
                'success': None,
                'task_id': task_id,
                'image_to_scan': full_image,
                'message': f'Task {task_id} started but did not finish within the wait window',
            })

        # 4. Read the container exit code: 0 = success, anything else = failure.
        task = ecs.describe_tasks(cluster=cluster, tasks=[task_arn])['tasks'][0]
        exit_code = task['containers'][0].get('exitCode')
        stopped_reason = task.get('stoppedReason', 'Unknown')
        print(f'Task {task_id} exit code {exit_code} ({stopped_reason})')

        logs_cmd = f'aws logs tail /ecs/Sysdig-Registry-Scanner --since 30m | grep {task_id}'
        if exit_code == 0:
            return _response(200, {
                'success': True,
                'task_id': task_id,
                'image_to_scan': full_image,
                'exit_code': exit_code,
                'message': f'Scan completed successfully for {image_to_scan}',
                'logs_command': logs_cmd,
            })
        return _response(500, {
            'success': False,
            'task_id': task_id,
            'image_to_scan': full_image,
            'exit_code': exit_code,
            'stopped_reason': stopped_reason,
            'message': f'Scan failed for {image_to_scan} with exit code {exit_code}',
            'logs_command': logs_cmd,
        })

    except Exception as e:
        print(f'Error: {e}')
        import traceback
        traceback.print_exc()
        return _response(500, {'success': False, 'error': str(e)})


def _as_list(value):
    if value is None:
        return []
    return [value] if isinstance(value, str) else value


def _response(status, body):
    return {'statusCode': status, 'body': json.dumps(body)}
