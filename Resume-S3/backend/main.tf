# Generate a unique string so your bucket name doesn't conflict globally
resource "random_id" "bucket_suffix" {
  byte_length = 4
}

# 1. The S3 Bucket itself
resource "aws_s3_bucket" "resume_site" {
  bucket = "my-resume-website-${random_id.bucket_suffix.hex}"
}

# 2. Configure the bucket to host a static website
resource "aws_s3_bucket_website_configuration" "resume_site_config" {
  bucket = aws_s3_bucket.resume_site.id

  index_document {
    suffix = "index.html"
  }
}

# 3. Disable "Block Public Access" so the internet can read the HTML pages
resource "aws_s3_bucket_public_access_block" "resume_site_public_block" {
  bucket = aws_s3_bucket.resume_site.id

  block_public_policy     = false
  block_public_acls       = false
  ignore_public_acls      = false
  restrict_public_buckets = false
}

# 4. A public read policy allowing web browsers to pull your site files
resource "aws_s3_bucket_policy" "resume_site_policy" {
  bucket = aws_s3_bucket.resume_site.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "PublicReadGetObject"
        Effect    = "Allow"
        Principal = "*"
        Action    = "s3:GetObject"
        Resource  = "${aws_s3_bucket.resume_site.arn}/*"
      }
    ]
  })

  # This makes sure the public access block is removed BEFORE the policy applies
  depends_on = [aws_s3_bucket_public_access_block.resume_site_public_block]
}

# Output the URL to your terminal screen
output "secure_website_url" {
  value       = "https://${aws_cloudfront_distribution.s3_distribution.domain_name}"
  description = "Your new secure HTTPS website link powered by CloudFront CDN"
}

output "bucket_name" {
  value       = aws_s3_bucket.resume_site.id
  description = "The exact name of your generated S3 bucket"
}

#backend visitor counter

# Create the DynamoDB Table
resource "aws_dynamodb_table" "visitor_counter" {
  name         = "resume-visitor-counter"
  billing_mode = "PAY_PER_REQUEST" # Serverless billing (free for low volume)
  hash_key     = "id"

  attribute {
    name = "id"
    type = "S" # "S" stands for String data type
  }
}

# Insert the initial counter item into the database so it starts at 0
resource "aws_dynamodb_table_item" "init_count" {
  table_name = aws_dynamodb_table.visitor_counter.name
  hash_key   = aws_dynamodb_table.visitor_counter.hash_key

  item = jsonencode({
    "id"    = { S = "visitors" }
    "count" = { N = "0" } # "N" stands for Number data type
  })
  
  # Prevents Terraform from overwriting and resetting the count back to 0 on future updates
  lifecycle {
    ignore_changes = [item]
  }
}

# Create the Security Role for Lambda
resource "aws_iam_role" "lambda_exec_role" {
  name = "resume_lambda_execution_role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

# Attach basic CloudWatch logging permissions to the Role
resource "aws_iam_role_policy_attachment" "lambda_logs" {
  role       = aws_iam_role.lambda_exec_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Attach a custom policy allowing the Lambda function to talk to your DynamoDB table
resource "aws_iam_policy" "lambda_dynamodb_policy" {
  name        = "lambda_dynamodb_visitor_counter_policy"
  description = "Allows Lambda to update items in the specific visitor counter DynamoDB table"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = [
        "dynamodb:GetItem",
        "dynamodb:UpdateItem"
      ]
      Resource = aws_dynamodb_table.visitor_counter.arn
    }]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_dynamo_attach" {
  role       = aws_iam_role.lambda_exec_role.name
  policy_arn = aws_iam_policy.lambda_dynamodb_policy.arn
}

# Create the Python deployment package inline
data "archive_file" "lambda_zip" {
  type        = "zip"
  output_path = "${path.module}/lambda_function.zip"

  source {
    filename = "lambda_function.py"
    content  = <<EOF
import json
import boto3

dynamodb = boto3.resource('dynamodb')
table = dynamodb.Table('resume-visitor-counter')

def lambda_handler(event, context):
    # Atomic update: increments 'count' by 1 and returns the updated value
    response = table.update_item(
        Key={'id': 'visitors'},
        UpdateExpression='ADD #c :val',
        ExpressionAttributeNames={'#c': 'count'},
        ExpressionAttributeValues={':val': 1},
        ReturnValues='UPDATED_NEW'
    )
    
    # Extract the new count value from the response
    views = int(response['Attributes']['count'])
    
    return {
        'statusCode': 200,
        'headers': {
            'Access-Control-Allow-Origin': '*', # Allows your frontend website to read the data safely
            'Access-Control-Allow-Headers': 'Content-Type',
            'Access-Control-Allow-Methods': 'GET,POST,OPTIONS'
        },
        'body': json.dumps({'count': views})
    }
EOF
  }
}

# Define the AWS Lambda function resource
resource "aws_lambda_function" "visitor_counter_lambda" {
  filename         = data.archive_file.lambda_zip.output_path
  function_name    = "resume-visitor-counter-backend"
  role             = aws_iam_role.lambda_exec_role.arn
  handler          = "lambda_function.lambda_handler"
  runtime          = "python3.11"
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
}

# Create the HTTP API Gateway
resource "aws_apigatewayv2_api" "http_api" {
  name          = "resume-visitor-counter-api"
  protocol_type = "HTTP"
}

# Target integration connecting the Gateway directly to your Lambda function
resource "aws_apigatewayv2_integration" "lambda_integration" {
  api_id           = aws_apigatewayv2_api.http_api.id
  integration_type = "AWS_PROXY"
  integration_uri  = aws_lambda_function.visitor_counter_lambda.arn
}

# Map a default route ("/") that forwards any incoming request to the Lambda integration
resource "aws_apigatewayv2_route" "default_route" {
  api_id    = aws_apigatewayv2_api.http_api.id
  route_key = "ANY /"
  target    = "integrations/${aws_apigatewayv2_integration.lambda_integration.id}"
}

# Deploy the API stage into live production automatically
resource "aws_apigatewayv2_stage" "api_stage" {
  api_id      = aws_apigatewayv2_api.http_api.id
  name        = "$default"
  auto_deploy = true
}

# Give API Gateway permissions to execute your Lambda function
resource "aws_lambda_permission" "api_gateway_permission" {
  statement_id  = "AllowExecutionFromAPIGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.visitor_counter_lambda.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.http_api.execution_arn}/*/*"
}

# Print your public API URL endpoint straight to your terminal screen
output "api_url" {
  value       = aws_apigatewayv2_api.http_api.api_endpoint
  description = "The backend endpoint URL your Javascript code will query to update the visitor counter"
}

#HTTPS Protocol .tf Code

# Create the CloudFront Distribution for HTTPS
resource "aws_cloudfront_distribution" "s3_distribution" {
  origin {
    # Points to your S3 bucket's website server domain endpoint
    domain_name = aws_s3_bucket_website_configuration.resume_site_config.website_endpoint
    origin_id   = "S3-.${aws_s3_bucket.resume_site.id}"

    custom_origin_config {
      http_port                = 80
      https_port               = 443
      origin_protocol_policy   = "http-only" # S3 website endpoints only speak HTTP
      origin_ssl_protocols     = ["TLSv1.2"]
    }
  }

  enabled             = true
  is_ipv6_enabled     = true
  default_root_object = "index.html"

  # Configures caching and behavior rules
  default_cache_behavior {
    allowed_methods  = ["GET", "HEAD"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = "S3-.${aws_s3_bucket.resume_site.id}"

    forwarded_values {
      query_string = false
      cookies { forward = "none" }
    }

    # CRUCIAL: Redirects anyone typing http:// automatically to secure https://
    viewer_protocol_policy = "redirect-to-https"
    min_ttl                = 0
    default_ttl            = 3600
    max_ttl                = 86400
  }

  # Uses the default, free *.cloudfront.net SSL certificate
  viewer_certificate {
    cloudfront_default_certificate = true
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }
}