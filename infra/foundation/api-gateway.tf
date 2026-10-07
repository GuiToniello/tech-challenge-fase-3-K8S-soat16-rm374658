resource "aws_apigatewayv2_api" "this" {
  name          = "${var.project_name}-api"
  protocol_type = "HTTP"
}

resource "aws_apigatewayv2_vpc_link" "this" {
  name               = "${var.project_name}-vpc-link"
  subnet_ids         = aws_subnet.private[*].id
  security_group_ids = [aws_security_group.vpc_link.id]
}

# Remove o prefixo da API (/monolith/api/x -> /api/x), como o rewrite-target do antigo Ingress.
# $request.path.proxy vem sem a barra inicial; fica sem chaves para o HCL nao interpolar.
resource "aws_apigatewayv2_integration" "apis" {
  for_each = local.api_node_ports

  api_id             = aws_apigatewayv2_api.this.id
  integration_type   = "HTTP_PROXY"
  integration_method = "ANY"
  integration_uri    = aws_lb_listener.apis[each.key].arn
  connection_type    = "VPC_LINK"
  connection_id      = aws_apigatewayv2_vpc_link.this.id

  request_parameters = {
    "overwrite:path" = "/$request.path.proxy"
  }
}

resource "aws_apigatewayv2_route" "apis" {
  for_each = local.api_node_ports

  api_id             = aws_apigatewayv2_api.this.id
  route_key          = "ANY /${each.key}/{proxy+}"
  target             = "integrations/${aws_apigatewayv2_integration.apis[each.key].id}"
  authorization_type = "CUSTOM"
  authorizer_id      = aws_apigatewayv2_authorizer.lambda.id
}

# Lambda authorizer (repo LAMBDA): exige JWT valido do Auth0 com a claim cpf; o cadastro de
# cliente aceita JWT sem cpf. Sem header Authorization, o gateway responde 401 sem invocar a Lambda.
# Sem cache (TTL 0): a decisao depende da rota, nao so do token.
resource "aws_apigatewayv2_authorizer" "lambda" {
  api_id                            = aws_apigatewayv2_api.this.id
  name                              = "${var.project_name}-authorizer"
  authorizer_type                   = "REQUEST"
  authorizer_uri                    = "arn:aws:apigateway:${var.aws_region}:lambda:path/2015-03-31/functions/${local.lambda_authorizer_arn}/invocations"
  identity_sources                  = ["$request.header.Authorization"]
  authorizer_payload_format_version = "2.0"
  enable_simple_responses           = true
  authorizer_result_ttl_in_seconds  = 0
}

# /health publico: a rota exata tem prioridade sobre {proxy+} e nao passa pelo authorizer.
# Integracao propria porque esta rota nao tem $request.path.proxy.
resource "aws_apigatewayv2_integration" "health" {
  for_each = local.api_node_ports

  api_id             = aws_apigatewayv2_api.this.id
  integration_type   = "HTTP_PROXY"
  integration_method = "ANY"
  integration_uri    = aws_lb_listener.apis[each.key].arn
  connection_type    = "VPC_LINK"
  connection_id      = aws_apigatewayv2_vpc_link.this.id

  request_parameters = {
    "overwrite:path" = "/health"
  }
}

resource "aws_apigatewayv2_route" "health" {
  for_each = local.api_node_ports

  api_id    = aws_apigatewayv2_api.this.id
  route_key = "GET /${each.key}/health"
  target    = "integrations/${aws_apigatewayv2_integration.health[each.key].id}"
}

# Geracao do JWT com a claim cpf (Lambda issue-token do repo LAMBDA). Rota publica: e o login.
resource "aws_apigatewayv2_integration" "issue_token" {
  api_id                 = aws_apigatewayv2_api.this.id
  integration_type       = "AWS_PROXY"
  integration_method     = "POST"
  integration_uri        = local.lambda_issue_token_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "issue_token" {
  api_id    = aws_apigatewayv2_api.this.id
  route_key = "POST /auth/token"
  target    = "integrations/${aws_apigatewayv2_integration.issue_token.id}"
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.this.id
  name        = "$default"
  auto_deploy = true
}