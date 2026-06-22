output "bucket_name" {
  value       = aws_s3_bucket.web.id
  description = "S3 bucket name — use as S3_BUCKET in GitHub environment vars"
}

output "bucket_arn" {
  value       = aws_s3_bucket.web.arn
  description = "S3 bucket ARN (used in IAM policies)"
}

output "cloudfront_id" {
  value       = aws_cloudfront_distribution.web.id
  description = "CloudFront distribution ID — use as CLOUDFRONT_ID in GitHub environment vars"
}

output "cloudfront_domain" {
  value       = aws_cloudfront_distribution.web.domain_name
  description = "CloudFront default domain (use as CNAME source before custom domain is configured)"
}

output "cloudfront_arn" {
  value       = aws_cloudfront_distribution.web.arn
  description = "CloudFront distribution ARN (used in IAM and WAF policies)"
}
