#!/bin/bash

# Try to get the OpenShift Route first (used in ambient mode)
# If it doesn't exist, fall back to Gateway API LoadBalancer address (used in sidecar mode)
ROUTE_HOST=$(oc get route hello-gateway -n istio-ingress -o jsonpath='{.spec.host}' 2>/dev/null)

if [ -n "$ROUTE_HOST" ]; then
    echo "Using OpenShift Route (ambient mode): $ROUTE_HOST"
    export GATEWAY="$ROUTE_HOST"
else
    echo "Using Gateway API LoadBalancer (sidecar mode)"
    export GATEWAY=$(oc get gateway hello-gateway -n istio-ingress -o template --template='{{(index .status.addresses 0).value}}')
    echo "Gateway address: $GATEWAY"
fi

echo ""
echo "Testing /hello endpoint..."
RESPONSE=$(curl -s --max-time 10 http://$GATEWAY/hello)
if [ $? -eq 0 ] && [ -n "$RESPONSE" ]; then
    echo "$RESPONSE" | jq
else
    echo "⚠ Request failed or timed out. This may happen with LoadBalancer endpoints."
    echo "Try accessing directly: curl http://$GATEWAY/hello"
    exit 1
fi

echo ""
echo "Testing /hello-service endpoint..."
RESPONSE=$(curl -s --max-time 10 http://$GATEWAY/hello-service)
if [ $? -eq 0 ] && [ -n "$RESPONSE" ]; then
    echo "$RESPONSE" | jq
else
    echo "⚠ Request failed or timed out"
    exit 1
fi

echo ""
echo "✓ REST API is accessible and working!"