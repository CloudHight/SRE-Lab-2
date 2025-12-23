import json
import boto3
import os

def lambda_handler(event, context):
    client = boto3.client('ssm')
    
    incident_data = event.get('detail', {})
    
    # Automated response based on incident type
    if 'database' in incident_data.get('description', '').lower():
        # Run SSM automation document for database incidents
        response = client.start_automation_execution(
            DocumentName='AWS-RestartRDSInstance',
            Parameters={
                'InstanceId': [incident_data.get('resource_id', '')]
            }
        )
    
    elif 'ec2' in incident_data.get('description', '').lower():
        # Run EC2 recovery automation
        response = client.start_automation_execution(
            DocumentName='AWSEC2-RestartInstanceAndWait',
            Parameters={
                'InstanceId': [incident_data.get('resource_id', '')]
            }
        )
    
    return {
        'statusCode': 200,
        'body': json.dumps('Incident response triggered')
    }