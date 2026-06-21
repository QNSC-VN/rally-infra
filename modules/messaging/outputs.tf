output "queue_urls" {
  value       = { for k, v in aws_sqs_queue.main : k => v.url }
  description = "Map of queue name → URL"
}
output "queue_arns" {
  value = { for k, v in aws_sqs_queue.main : k => v.arn }
}
output "dlq_arns" {
  value = { for k, v in aws_sqs_queue.dlq : k => v.arn }
}
output "topic_arns" {
  value = { for k, v in aws_sns_topic.events : k => v.arn }
}
