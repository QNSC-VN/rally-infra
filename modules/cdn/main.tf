# =============================================================================
# CDN — S3 + CloudFront for Rally Web (SPA)
#
# Architecture:
#   GitHub Actions → S3 sync → CloudFront (OAC) → User
#
# Key design decisions:
#   - S3 bucket is fully private; only CloudFront (via OAC) can read objects
#   - CloudFront Function rewrites sub-paths to /index.html (SPA routing)
#   - index.html served with no-cache headers (set at deploy time via s3 cp)
#   - Static assets (/assets/*) use Managed CachingOptimized (1 year TTL)
#   - Custom error responses map 403/404 → 200 /index.html (S3 + SPA routing)
# =============================================================================

# ── S3 Bucket ─────────────────────────────────────────────────────────────────
resource "aws_s3_bucket" "web" {
  bucket = var.name
  tags   = var.tags
}

resource "aws_s3_bucket_public_access_block" "web" {
  bucket = aws_s3_bucket.web.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "web" {
  bucket = aws_s3_bucket.web.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_versioning" "web" {
  bucket = aws_s3_bucket.web.id
  versioning_configuration {
    status = "Disabled"   # SPA build output is ephemeral — no need to version
  }
}

# ── CloudFront Origin Access Control (OAC) ────────────────────────────────────
# OAC is the modern replacement for OAI — uses SigV4 signing.
resource "aws_cloudfront_origin_access_control" "web" {
  name                              = var.name
  description                       = "OAC for ${var.name} S3 bucket"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# ── CloudFront Function — SPA client-side routing ────────────────────────────
# Rewrites any request URI without a file extension to /index.html,
# so React Router can handle deep-links on the client side.
# Runs at viewer-request stage (edge, before cache check — very low latency).
resource "aws_cloudfront_function" "spa_redirect" {
  name    = "${var.name}-spa-redirect"
  runtime = "cloudfront-js-2.0"
  comment = "Rewrite non-asset URIs to /index.html for SPA routing"
  publish = true

  code = <<-EOT
    function handler(event) {
      var request = event.request;
      var uri = request.uri;

      // Pass through requests that already have a file extension
      // (JS chunks, CSS, images, fonts, manifests, etc.)
      if (!uri.match(/\.[a-zA-Z0-9]+$/)) {
        request.uri = '/index.html';
      }

      return request;
    }
  EOT
}

# ── CloudFront Distribution ───────────────────────────────────────────────────
resource "aws_cloudfront_distribution" "web" {
  enabled             = true
  is_ipv6_enabled     = true
  default_root_object = "index.html"
  price_class         = var.price_class
  aliases             = var.aliases

  origin {
    domain_name              = aws_s3_bucket.web.bucket_regional_domain_name
    origin_id                = "s3-${var.name}"
    origin_access_control_id = aws_cloudfront_origin_access_control.web.id
  }

  # ── Default cache behaviour — serves index.html + assets ──────────────────
  default_cache_behavior {
    target_origin_id       = "s3-${var.name}"
    viewer_protocol_policy = "redirect-to-https"
    compress               = true

    allowed_methods = ["GET", "HEAD", "OPTIONS"]
    cached_methods  = ["GET", "HEAD"]

    # Managed-CachingOptimized: 1yr TTL for immutable assets.
    # index.html cache-control is overridden at deploy time (s3 cp --cache-control no-cache).
    cache_policy_id = "658327ea-f89d-4fab-a63d-7e88639e58f6"

    function_association {
      event_type   = "viewer-request"
      function_arn = aws_cloudfront_function.spa_redirect.arn
    }
  }

  # ── SPA routing: map S3 errors to index.html + 200 ───────────────────────
  # 403 = S3 OAC denial (key doesn't exist), 404 = key not found.
  # Both mean the path is a React Router route, not a real file.
  custom_error_response {
    error_code            = 403
    response_code         = 200
    response_page_path    = "/index.html"
    error_caching_min_ttl = 0
  }

  custom_error_response {
    error_code            = 404
    response_code         = 200
    response_page_path    = "/index.html"
    error_caching_min_ttl = 0
  }

  viewer_certificate {
    acm_certificate_arn      = var.acm_cert_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  tags = var.tags
}

# ── S3 Bucket Policy — CloudFront OAC only ────────────────────────────────────
# The Condition on SourceArn ensures only THIS distribution can read the bucket,
# not any CloudFront distribution in the account.
resource "aws_s3_bucket_policy" "web" {
  bucket = aws_s3_bucket.web.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowCloudFrontOACRead"
        Effect = "Allow"
        Principal = {
          Service = "cloudfront.amazonaws.com"
        }
        Action   = "s3:GetObject"
        Resource = "${aws_s3_bucket.web.arn}/*"
        Condition = {
          StringEquals = {
            "AWS:SourceArn" = aws_cloudfront_distribution.web.arn
          }
        }
      }
    ]
  })

  # Policy can only be applied after the distribution exists
  depends_on = [aws_cloudfront_distribution.web]
}
