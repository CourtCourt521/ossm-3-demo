#!/bin/bash

NC=''          # Text Reset
BGreen='\033[1;32m'   # Green
BYellow='\033[1;33m'  # Yellow
#BBlack='\033[1;30m'  # Black
#BRed='\033[1;31m'    # Red
BBlue=''    # Blue
#BPurple='\033[1;35m' # Purple
#BCyan='\033[1;36m'   # Cyan
#BWhite='\033[1;37m'  # White

# Argument parsing for installation mode
INSTALL_MODE="${1:-sidecar}"  # Default to sidecar for backward compatibility

if [[ "$INSTALL_MODE" != "sidecar" && "$INSTALL_MODE" != "ambient" ]]; then
    echo "Error: Invalid installation mode '$INSTALL_MODE'"
    echo "Usage: $0 [sidecar|ambient]"
    echo "  sidecar - Traditional sidecar proxy mode (default)"
    echo "  ambient - Ambient mesh mode with ZTunnel and Waypoint"
    exit 1
fi

echo "This script sets up the whole OSSM3 demo in ${INSTALL_MODE} mode."

echo "Installing Minio for Tempo"
oc new-project tracing-system
oc apply -f ./resources/TempoOtel/minio.yaml -n tracing-system
echo "Waiting for Minio to become available..."
oc wait --for condition=Available deployment/minio --timeout 150s -n tracing-system

echo "Installing TempoCR"
oc apply -f ./resources/TempoOtel/tempo.yaml -n tracing-system
echo "Waiting for TempoStack to become ready..."
oc wait --for condition=Ready TempoStack/sample --timeout 150s -n tracing-system
echo "Waiting for Tempo deployment to become available..."
oc wait --for condition=Available deployment/tempo-sample-compactor --timeout 150s -n tracing-system

echo "Waiting for Tempo query-frontend service to be ready..."
timeout=30
until oc get endpoints tempo-sample-query-frontend -n tracing-system -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null | grep -q .; do
    echo "Waiting for service endpoints..."
    sleep 2
    ((timeout--))
    if [ $timeout -le 0 ]; then
        echo "Warning: Tempo query-frontend endpoints not ready, continuing anyway..."
        break
    fi
done

echo "Exposing Jaeger UI route (will be used in kiali ui)"
oc expose svc tempo-sample-query-frontend --port=jaeger-ui --name=tracing-ui -n tracing-system

echo "Installing OpenTelemetryCollector..."
oc new-project opentelemetrycollector
oc apply -f ./resources/TempoOtel/opentelemetrycollector.yaml -n opentelemetrycollector
echo "Waiting for OpenTelemetryCollector deployment to become available..."
oc wait --for condition=Available deployment/otel-collector --timeout 60s -n opentelemetrycollector

if [[ "$INSTALL_MODE" == "sidecar" ]]; then
    echo "=== Installing Sidecar Mode Service Mesh ==="
    echo "Installing OSSM3..."
    oc new-project istio-system
    echo "Installing IstioCR..."
    oc apply -f ./resources/OSSM3/istiocr.yaml  -n istio-system
    echo "Waiting for istio to become ready..."
    oc wait --for condition=Ready istio/default --timeout 60s  -n istio-system

    echo "Installing Telemetry resource..."
    oc apply -f ./resources/TempoOtel/istioTelemetry.yaml  -n istio-system
    echo "Adding OTEL namespace as a part of the mesh"
    oc label namespace opentelemetrycollector istio-injection=enabled
fi

if [[ "$INSTALL_MODE" == "ambient" ]]; then
    echo "=== Installing Ambient Mode Service Mesh ==="
    echo "Installing OSSM3 with Ambient profile..."
    oc new-project istio-system
    oc label namespace istio-system istio-discovery=enabled
    echo "Installing Istio CR (ambient profile)..."
    oc apply -f ./resources/OSSM3Ambient/istioambientcr.yaml -n istio-system
    echo "Waiting for Istio to become ready..."
    oc wait --for condition=Ready istio/default --timeout 150s -n istio-system

    echo "Installing Telemetry resource..."
    oc apply -f ./resources/TempoOtel/istioTelemetry.yaml -n istio-system

    echo "Creating istio-cni namespace with discovery label..."
    oc create namespace istio-cni
    oc label namespace istio-cni istio-discovery=enabled
    echo "Installing IstioCNI (ambient profile)..."
    oc apply -f ./resources/OSSM3Ambient/istioambientCni.yaml -n istio-cni
    echo "Waiting for IstioCNI to become ready..."
    oc wait --for condition=Ready istiocni/default --timeout 150s -n istio-cni

    echo "Creating ztunnel namespace..."
    oc create namespace ztunnel
    echo "Installing ZTunnel..."
    oc apply -f ./resources/OSSM3Ambient/ztunnel.yaml -n ztunnel
    echo "Waiting for ZTunnel to become ready..."
    oc wait --for condition=Ready ztunnel/default --timeout 150s -n ztunnel
    echo "Waiting for ZTunnel DaemonSet pods..."
    oc wait --for=condition=Ready pods -l app=ztunnel -n ztunnel --timeout=150s

    echo "Adding OTEL namespace as part of the mesh"
    oc label namespace opentelemetrycollector istio-injection=enabled
fi

if [[ "$INSTALL_MODE" == "sidecar" ]]; then
    echo "Installing IstioCNI..."
    oc new-project istio-cni
    oc apply -f ./resources/OSSM3/istioCni.yaml -n istio-cni
    echo "Waiting for istiocni to become ready..."
    oc wait --for condition=Ready istiocni/default --timeout 60s -n istio-cni

    echo "Creating ingress gateway via Gateway API..."
    oc new-project istio-ingress
    echo "Adding istio-ingress namespace as a part of the mesh"
    oc label namespace istio-ingress istio-injection=enabled
    oc apply -k ./resources/gateway

    echo "Creating ingress gateway via Istio Deployment..."
    oc apply -f ./resources/OSSM3/istioIngressGateway.yaml  -n istio-ingress
    echo "Waiting for deployment/istio-ingressgateway to become available..."
    oc wait --for condition=Available deployment/istio-ingressgateway --timeout 60s -n istio-ingress
    echo "Exposing Istio ingress route"
    oc expose svc istio-ingressgateway --port=http2 --name=istio-ingressgateway -n istio-ingress
fi

if [[ "$INSTALL_MODE" == "ambient" ]]; then
    echo "Creating Gateway API infrastructure for REST API (ambient mode)..."
    oc new-project istio-ingress
    echo "Adding istio-ingress namespace to ambient mesh"
    oc label namespace istio-ingress istio.io/dataplane-mode=ambient
    oc apply -k ./resources/gateway
    echo "Waiting for Gateway to be programmed..."
    oc wait --for=condition=Programmed gateway/hello-gateway -n istio-ingress --timeout=60s

    echo "Exposing hello-gateway via OpenShift Route..."
    oc expose svc hello-gateway-istio --port=http --name=hello-gateway -n istio-ingress
fi

echo "Enabling user workload monitoring in OCP"
oc apply -f ./resources/Monitoring/ocpUserMonitoring.yaml
echo "Enabling service monitor in istio-system namespace"
oc apply -f ./resources/Monitoring/serviceMonitor.yaml -n istio-system
echo "Enabling pod monitor in istio-system namespace"
oc apply -f ./resources/Monitoring/podMonitor.yaml -n istio-system
echo "Enabling pod monitor in istio-ingress namespace"
oc apply -f ./resources/Monitoring/podMonitor.yaml -n istio-ingress

echo "Installing Kiali..."
oc project istio-system
echo "Creating cluster role binding for kiali to read ocp monitoring"
oc apply -f ./resources/Kiali/kialiCrb.yaml -n istio-system
echo "Installing KialiCR..."
export TRACING_INGRESS_ROUTE="http://$(oc get -n tracing-system route tracing-ui -o jsonpath='{.spec.host}')"
cat ./resources/Kiali/kialiCr.yaml | JAEGERROUTE="${TRACING_INGRESS_ROUTE}" envsubst | oc -n istio-system apply -f - 
echo "Waiting for kiali to become ready..."
oc wait --for condition=Successful kiali/kiali --timeout 150s -n istio-system 
oc annotate route kiali haproxy.router.openshift.io/timeout=60s -n istio-system 

echo "Install Kiali OSSM Console plugin..."
oc apply -f ./resources/Kiali/kialiOssmcCr.yaml -n istio-system

if [[ "$INSTALL_MODE" == "sidecar" ]]; then
    echo "Installing Sample RestAPI (sidecar mode)..."
    oc apply -k ./resources/application/kustomize/overlays/pod
else
    echo "Installing Sample RestAPI (ambient mode)..."
    oc apply -k ./resources/application/kustomize/overlays/ambient
fi 

echo "Installing Bookinfo application..."
oc new-project bookinfo

if [[ "$INSTALL_MODE" == "sidecar" ]]; then
    echo "Configuring Bookinfo for sidecar mode..."
    oc label namespace bookinfo istio-injection=enabled
    echo "Enabling pod monitor in bookinfo namespace"
    oc apply -f ./resources/Monitoring/podMonitor.yaml -n bookinfo
    echo "Installing Bookinfo application"
    oc apply -f ./resources/Bookinfo/bookinfo.yaml -n bookinfo
    echo "Waiting for bookinfo pods to become ready..."
    oc wait --for=condition=Ready pods --all -n bookinfo --timeout 150s

    echo "Installing Bookinfo Gateway and VirtualService..."
    oc apply -f ./resources/Bookinfo/bookinfo-gateway.yaml -n bookinfo

else  # ambient mode
    echo "Configuring Bookinfo for ambient mode..."
    oc label namespace bookinfo istio.io/dataplane-mode=ambient
    echo "Enabling pod monitor in bookinfo namespace"
    oc apply -f ./resources/Monitoring/podMonitor.yaml -n bookinfo
    echo "Installing Bookinfo application"
    oc apply -f ./resources/Bookinfo/bookinfo.yaml -n bookinfo
    echo "Waiting for bookinfo pods to become ready..."
    oc wait --for=condition=Ready pods --all -n bookinfo --timeout 150s

    echo "Installing Waypoint Gateway for L7 processing..."
    oc apply -f ./resources/OSSM3Ambient/waypointgateway.yaml -n bookinfo
    echo "Waiting for Waypoint Gateway to be programmed..."
    oc wait --for=condition=Programmed gateway/bookinfo-waypoint -n bookinfo --timeout=150s
    echo "Waiting for Waypoint deployment..."
    oc wait --for=condition=Available deployment/bookinfo-waypoint -n bookinfo --timeout=150s

    echo "Configuring namespace to use Waypoint..."
    oc label namespace bookinfo istio.io/use-waypoint=bookinfo-waypoint
    oc label namespace bookinfo istio.io/ingress-use-waypoint=true

    echo "Creating Kubernetes Gateway for BookInfo ingress..."
    oc apply -f ./resources/OSSM3Ambient/bookinfogateway.yaml -n bookinfo
    echo "Waiting for Gateway to be programmed..."
    oc wait --for=condition=Programmed gateway/bookinfo-ingress-gateway -n bookinfo --timeout=60s

    echo "Creating OpenShift Route for BookInfo edge..."
    oc apply -f ./resources/OSSM3Ambient/routebookinfo.yaml -n bookinfo
    echo "Waiting for Route to be ready..."
    sleep 5

    echo "Retrieving cluster route hostname..."
    export BOOKINFO_ROUTE_HOSTNAME=$(oc get route bookinfo-edge -n bookinfo -o jsonpath='{.spec.host}')
    echo "Cluster route hostname: ${BOOKINFO_ROUTE_HOSTNAME}"

    echo "Creating HTTPRoute with dynamic hostname..."
    cat ./resources/OSSM3Ambient/HTTPRoutebookinfo.yaml.template | envsubst | oc apply -f -
fi

echo "Installation finished!"
echo "NOTE: Kiali will show metrics of bookinfo app right after pod monitor will be ready. You can check it in OCP console Observe->Metrics"

# Set appropriate ingress host based on mode
if [[ "$INSTALL_MODE" == "sidecar" ]]; then
    export INGRESSHOST=$(oc get route istio-ingressgateway -n istio-ingress -o=jsonpath='{.spec.host}')
else  # ambient
    export INGRESSHOST=$(oc get route bookinfo-edge -n bookinfo -o=jsonpath='{.spec.host}')
fi

KIALI_HOST=$(oc get route kiali -n istio-system -o=jsonpath='{.spec.host}')

echo "[optional] Installing Bookinfo traffic generator..."
cat ./resources/Bookinfo/traffic-generator-configmap.yaml | ROUTE="http://${INGRESSHOST}/productpage" envsubst | oc -n bookinfo apply -f -
oc apply -f ./resources/Bookinfo/traffic-generator.yaml -n bookinfo

echo "===================================================================================================="
echo "Installation Mode: ${INSTALL_MODE}"
echo "Ingress route for bookinfo is: http://${INGRESSHOST}/productpage"
echo "To test RestAPI: sh ./scripts/test-api.sh"
echo "Kiali route is: https://${KIALI_HOST}"
echo "===================================================================================================="
