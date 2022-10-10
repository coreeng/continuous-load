package integration

import (
	"context"
	"crypto/tls"
	"fmt"
	"io"
	"io/ioutil"
	"net"
	"net/http"
	"os"
	"strings"
	"testing"
	"time"

	. "github.com/onsi/ginkgo"
	. "github.com/onsi/gomega"
	"github.com/prometheus/client_golang/api"
	v1 "github.com/prometheus/client_golang/api/prometheus/v1"
	"github.com/prometheus/common/model"
)

func TestIntegration(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "Integration Suite")
}

var _ = Describe("Continuous Load", func() {
	var (
		httpClient    *http.Client
		httpTransport *http.Transport
		sourceURL     string
		targetURL     string
		prometheusURL string
		cluster       string
		region        string
		queryRange    time.Duration
	)

	doHTTPRequest := func(url string, method string, body io.Reader) (statusCode int, payload string) {
		req, err := http.NewRequest(method, url, body)

		Expect(err).To(BeNil(), "request creation failed")
		httpClientTimeout := 2 * time.Second
		ctx, cancel := context.WithTimeout(req.Context(), httpClientTimeout)
		defer cancel()

		// call backend
		resp, err := httpClient.Do(req.WithContext(ctx))
		Expect(err).To(BeNil(), "request call failed")
		defer resp.Body.Close()

		respBody, err := ioutil.ReadAll(resp.Body)
		Expect(err).To(BeNil(), "read body failed")

		// Convert the body to type string
		sb := string(respBody)

		return resp.StatusCode, sb
	}

	prometheusQuery := func(url string, query string, queryRange time.Duration) model.Value {
		var rt http.RoundTripper = httpTransport

		client, err := api.NewClient(api.Config{
			Address:      url,
			RoundTripper: rt,
		})

		Expect(err).To(BeNil(), "creating prometheus client failed")

		v1api := v1.NewAPI(client)
		ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		defer cancel()

		r := v1.Range{
			Start: time.Now().Add(-queryRange),
			End:   time.Now(),
			Step:  time.Minute,
		}
		result, warnings, err := v1api.QueryRange(ctx, query, r)
		Expect(err).To(BeNil(), "querying Prometheus failed")

		if len(warnings) > 0 {
			fmt.Printf("Warnings: #{warnings}\n")
		}

		return result
	}

	BeforeSuite(func() {
		httpTransport = &http.Transport{
			Dial: (&net.Dialer{
				Timeout:   3 * time.Second,
				KeepAlive: 3 * time.Second,
			}).Dial,
			TLSHandshakeTimeout:   3 * time.Second,
			ResponseHeaderTimeout: 3 * time.Second,
			IdleConnTimeout:       3 * time.Second,
			TLSClientConfig:       &tls.Config{InsecureSkipVerify: true},
		}

		httpClient = &http.Client{
			Transport: httpTransport,
		}

		sourceURL = ""
		if sourceURLENV := os.Getenv("TEST_SOURCE_URL"); sourceURLENV != "" {
			sourceURL = sourceURLENV
		}

		targetURL = ""
		if targetURLENV := os.Getenv("TEST_TARGET_URL"); targetURLENV != "" {
			targetURL = targetURLENV
		}

		prometheusURL = ""
		if prometheusURLENV := os.Getenv("TEST_PROMETHEUS_URL"); prometheusURLENV != "" {
			prometheusURL = prometheusURLENV
		}

		cluster = ""
		if clusterENV := os.Getenv("TEST_CLUSTER"); clusterENV != "" {
			cluster = clusterENV
		}

		region = ""
		if regionENV := os.Getenv("TEST_REGION"); regionENV != "" {
			region = regionENV
		}

		queryRange = 3 * time.Minute
		fmt.Printf("Waiting for prometheus metrics to be available, sleeping for %s \n", queryRange)
		time.Sleep(queryRange)

	})

	Context("Source Podinfo", func() {
		It("is reachable through ingress", func() {
			statusCode, payload := doHTTPRequest(sourceURL, "GET", nil)

			Expect(statusCode).To(Equal(200))
			Expect(strings.Contains(payload, "source-podinfo")).To(BeTrue())
		})

		It("is reachable through forward/ingress", func() {
			statusCode, _ := doHTTPRequest(sourceURL+"/forward/ingress", "GET", nil)

			Expect(statusCode).To(Equal(200))
		})

		It("is reachable through forward/service", func() {
			statusCode, _ := doHTTPRequest(sourceURL+"/forward/service", "GET", nil)

			Expect(statusCode).To(Equal(200))
		})

		It("forward ingress metric is available on prometheus", func() {
			query := fmt.Sprintf("sum by (path, status) (rate(http_request_duration_seconds_count{"+
				"method=\"GET\", namespace=\"continuous-load-source\", "+
				"path=\"forward_ingress\", k8scluster= \"%s\", "+
				"region=\"%s\", app=\"source-podinfo\" }[1m]))", cluster, region)

			data := prometheusQuery(prometheusURL, query, queryRange)

			metricFound := false
			dataMatrix := data.(model.Matrix)

			for key, d := range dataMatrix {
				if d.Metric["path"] == "forward_ingress" && d.Metric["status"] == "200" {
					metricFound = true
					Expect(d.Values[key].Value).Should(BeNumerically(">", 15))
				}

				if d.Metric["path"] == "forward_ingress" && d.Metric["status"] != "200" {
					metricFound = true
					Expect(d.Values[key].Value).Should(BeNumerically("<", 0.1))
				}
			}

			Expect(metricFound).To(BeTrue())
		})

		It("forward service metric is available on prometheus", func() {
			query := fmt.Sprintf("sum by (path, status) (rate(http_request_duration_seconds_count{"+
				"method=\"GET\", namespace=\"continuous-load-source\", "+
				"path=\"forward_service\", k8scluster= \"%s\", "+
				"region=\"%s\", app=\"source-podinfo\" }[1m]))", cluster, region)

			data := prometheusQuery(prometheusURL, query, queryRange)

			metricFound := false
			dataMatrix := data.(model.Matrix)

			for key, d := range dataMatrix {
				if d.Metric["path"] == "forward_service" && d.Metric["status"] == "200" {
					metricFound = true
					Expect(d.Values[key].Value).Should(BeNumerically(">", 15))
				}

				if d.Metric["path"] == "forward_service" && d.Metric["status"] != "200" {
					metricFound = true
					Expect(d.Values[key].Value).Should(BeNumerically("<", 0.1))
				}
			}

			Expect(metricFound).To(BeTrue())
		})
	})

	Context("Target Podinfo", func() {
		It("is reachable through ingress", func() {
			statusCode, payload := doHTTPRequest(targetURL, "GET", nil)

			Expect(statusCode).To(Equal(200))
			Expect(strings.Contains(payload, "target-podinfo")).To(BeTrue())
		})

		It("is reachable through status/ingress", func() {
			statusCode, _ := doHTTPRequest(targetURL+"/status/ingress/200", "GET", nil)

			Expect(statusCode).To(Equal(200))
		})

		It("is reachable through status/service", func() {
			statusCode, _ := doHTTPRequest(targetURL+"/status/service/200", "GET", nil)

			Expect(statusCode).To(Equal(200))
		})

		It("status ingress metric is available on prometheus", func() {
			query := fmt.Sprintf("sum by (path, status) (rate(http_request_duration_seconds_count{"+
				"method=\"GET\", namespace=\"continuous-load-target\", "+
				"path=\"status_ingress\", k8scluster= \"%s\", "+
				"region=\"%s\", app=\"target-podinfo\" }[1m]))", cluster, region)

			data := prometheusQuery(prometheusURL, query, queryRange)

			metricFound := false
			dataMatrix := data.(model.Matrix)

			for key, d := range dataMatrix {
				if d.Metric["path"] == "status_ingress" && d.Metric["status"] == "200" {
					metricFound = true
					Expect(d.Values[key].Value).Should(BeNumerically(">", 15))
				}

				if d.Metric["path"] == "status_ingress" && d.Metric["status"] != "200" {
					metricFound = true
					Expect(d.Values[key].Value).Should(BeNumerically("<", 0.1))
				}
			}

			Expect(metricFound).To(BeTrue())
		})

		It("status service metric is available on prometheus", func() {
			query := fmt.Sprintf("sum by (path, status) (rate(http_request_duration_seconds_count{"+
				"method=\"GET\", namespace=\"continuous-load-target\", "+
				"path=\"status_service\", k8scluster= \"%s\", "+
				"region=\"%s\", app=\"target-podinfo\" }[1m]))", cluster, region)

			data := prometheusQuery(prometheusURL, query, queryRange)

			metricFound := false
			dataMatrix := data.(model.Matrix)

			for key, d := range dataMatrix {
				if d.Metric["path"] == "status_service" && d.Metric["status"] == "200" {
					metricFound = true
					Expect(d.Values[key].Value).Should(BeNumerically(">", 15))
				}

				if d.Metric["path"] == "status_service" && d.Metric["status"] != "200" {
					metricFound = true
					Expect(d.Values[key].Value).Should(BeNumerically("<", 0.1))
				}
			}

			Expect(metricFound).To(BeTrue())
		})
	})
})
