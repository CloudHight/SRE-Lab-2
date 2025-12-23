import os
import json
import boto3
from slack_bolt import App
from slack_bolt.adapter.aws_lambda import SlackRequestHandler
from openai import OpenAI
from langchain.chains import RetrievalQA
from langchain.llms import OpenAI as LangchainOpenAI
from langchain.embeddings import OpenAIEmbeddings
from langchain.vectorstores import MongoDBAtlasVectorSearch
from pymongo import MongoClient
import redis
from datetime import datetime

# Initialize AWS clients
ssm = boto3.client('secretsmanager', region_name='us-east-1')
dynamodb = boto3.resource('dynamodb', region_name='us-east-1')
sns = boto3.client('sns', region_name='us-east-1')

# Get Slack credentials
slack_secret = ssm.get_secret_value(SecretId='SlackCredentials')
slack_creds = json.loads(slack_secret['SecretString'])

# Initialize Slack app
app = App(
    token=slack_creds['SLACK_BOT_TOKEN'],
    signing_secret=slack_creds['SLACK_SIGNING_SECRET']
)

# Initialize OpenAI
openai_client = OpenAI(api_key=os.environ.get('OPENAI_API_KEY'))

# Initialize Redis for caching
redis_client = redis.Redis(
    host=os.environ.get('REDIS_HOST', 'localhost'),
    port=6379,
    decode_responses=True
)

# Incident history table
incidents_table = dynamodb.Table('IncidentHistory')

def get_ai_suggestions(incident_data):
    """Get AI-powered resolution suggestions based on past incidents"""
    
    # Check cache first
    cache_key = f"incident_suggestions:{incident_data.get('type', 'unknown')}"
    cached = redis_client.get(cache_key)
    
    if cached:
        return json.loads(cached)
    
    # Query similar past incidents from DynamoDB
    response = incidents_table.query(
        IndexName='incident_type-index',
        KeyConditionExpression='incident_type = :type',
        ExpressionAttributeValues={
            ':type': incident_data.get('type', 'general')
        },
        Limit=5
    )
    
    past_incidents = response.get('Items', [])
    
    # Prepare context for AI
    context = f"""
    Current Incident: {json.dumps(incident_data, indent=2)}
    
    Past Similar Incidents:
    {json.dumps(past_incidents, indent=2)}
    """
    
    # Get AI suggestions
    ai_response = openai_client.chat.completions.create(
        model="gpt-4",
        messages=[
            {"role": "system", "content": "You are an SRE assistant analyzing incidents. Provide step-by-step resolution suggestions."},
            {"role": "user", "content": f"Based on these past incidents and current incident data, provide resolution steps:\n\n{context}"}
        ],
        temperature=0.3,
        max_tokens=500
    )
    
    suggestions = ai_response.choices[0].message.content
    
    # Cache the suggestions
    redis_client.setex(cache_key, 3600, json.dumps({'suggestions': suggestions}))
    
    return {'suggestions': suggestions}

@app.event("app_mention")
def handle_mentions(event, say):
    """Handle mentions in Slack"""
    user = event["user"]
    text = event["text"]
    
    # Extract incident context from message
    incident_context = {
        "reported_by": user,
        "description": text,
        "timestamp": datetime.utcnow().isoformat()
    }
    
    # Get AI suggestions
    suggestions = get_ai_suggestions(incident_context)
    
    # Respond with suggestions
    say(
        blocks=[
            {
                "type": "section",
                "text": {
                    "type": "mrkdwn",
                    "text": f"👋 Hey <@{user}>, I've analyzed your issue."
                }
            },
            {
                "type": "section",
                "text": {
                    "type": "mrkdwn",
                    "text": "🤖 *AI-Powered Suggestions:*"
                }
            },
            {
                "type": "section",
                "text": {
                    "type": "mrkdwn",
                    "text": suggestions['suggestions']
                }
            },
            {
                "type": "actions",
                "elements": [
                    {
                        "type": "button",
                        "text": {
                            "type": "plain_text",
                            "text": "Acknowledge Incident"
                        },
                        "style": "primary",
                        "value": "acknowledge"
                    },
                    {
                        "type": "button",
                        "text": {
                            "type": "plain_text",
                            "text": "Need More Help"
                        },
                        "value": "help"
                    }
                ]
            }
        ]
    )

def handle_sns_notification(event, context):
    """Handle SNS notifications from AWS services"""
    for record in event['Records']:
        message = json.loads(record['Sns']['Message'])
        
        # Post to Slack channel
        app.client.chat_postMessage(
            channel=slack_creds['SLACK_CHANNEL_ID'],
            blocks=[
                {
                    "type": "section",
                    "text": {
                        "type": "mrkdwn",
                        "text": f"🚨 *New Incident Detected*"
                    }
                },
                {
                    "type": "section",
                    "fields": [
                        {
                            "type": "mrkdwn",
                            "text": f"*Service:*\n{message.get('service', 'Unknown')}"
                        },
                        {
                            "type": "mrkdwn",
                            "text": f"*Severity:*\n{message.get('severity', 'Medium')}"
                        }
                    ]
                },
                {
                    "type": "section",
                    "text": {
                        "type": "mrkdwn",
                        "text": f"*Description:*\n{message.get('description', 'No description')}"
                    }
                }
            ]
        )
        
        # Store in incident history
        incidents_table.put_item(Item={
            'incident_id': message.get('incident_id', str(datetime.utcnow().timestamp())),
            'timestamp': datetime.utcnow().isoformat(),
            'service': message.get('service', ''),
            'severity': message.get('severity', 'Medium'),
            'description': message.get('description', ''),
            'incident_type': message.get('type', 'general'),
            'status': 'open',
            'source': 'aws_sns'
        })

# Lambda handler
slack_handler = SlackRequestHandler(app=app)

def lambda_handler(event, context):
    if 'Records' in event and event['Records'][0]['EventSource'] == 'aws:sns':
        return handle_sns_notification(event, context)
    else:
        return slack_handler.handle(event, context)

if __name__ == "__main__":
    # For local testing
    from slack_bolt.adapter.socket_mode import SocketModeHandler
    SocketModeHandler(app, os.environ["SLACK_APP_TOKEN"]).start()