package api

import (
	"bytes"
	"context"
	"fmt"
	"io/ioutil"
	"net/http"
	"strings"
	"sync"

	"github.com/stefanprodan/podinfo/pkg/version"
	"go.uber.org/zap"
)

// Echo godoc
// @Summary Echo
// @Description forwards the call to the backend service and echos the posted content
// @Tags HTTP API
// @Accept json
// @Produce json
// @Router /api/echo [get, post]
// @Success 202 {object} api.MapResponse
func (s *Server) echoHandler(w http.ResponseWriter, r *http.Request) {
	s.forwardHandler(w, r, s.config.BackendURL)
}

// @Summary Service
// @Description forwards the call to the backend service and echos the posted content
// @Tags HTTP API
// @Accept json
// @Produce json
// @Router /forward/service [get, post]
// @Success 202 {object} api.MapResponse
func (s *Server) serviceHandler(w http.ResponseWriter, r *http.Request) {
	s.forwardHandler(w, r, s.config.BackendService)
}

// @Description forwards the call to the backend ingress and echos the posted content
// @Tags HTTP API
// @Accept json
// @Produce json
// @Router /forward/ingress [get, post]
// @Success 202 {object} api.MapResponse
func (s *Server) ingressHandler(w http.ResponseWriter, r *http.Request) {
	s.forwardHandler(w, r, s.config.BackendIngress)
}

func (s *Server) forwardHandler(w http.ResponseWriter, r *http.Request, backendUrl []string) {
	body, err := ioutil.ReadAll(r.Body)
	if err != nil {
		s.logger.Error("reading the request body failed", zap.Error(err))
		s.ErrorResponse(w, r, "invalid request body", http.StatusBadRequest)
		return
	}
	defer r.Body.Close()
	if len(backendUrl) > 0 {
		result := make([]string, len(backendUrl))
		statusCode := make([]int, len(backendUrl))
		var wg sync.WaitGroup
		wg.Add(len(backendUrl))
		for i, b := range backendUrl {
			go func(index int, backend string) {
				defer wg.Done()
				// provide a host overwrite "https://hostname.com|hostheader.com"
				backendSplit := strings.Split(backend, "|")
				backendReq, err := http.NewRequest(r.Method, backendSplit[0], bytes.NewReader(body))
				if err != nil {
					s.logger.Error("backend call failed", zap.Error(err), zap.String("url", backend))
					return
				}

				// forward headers
				copyTracingHeaders(r, backendReq)

				backendReq.Header.Set("X-API-Version", version.VERSION)
				backendReq.Header.Set("X-API-Revision", version.REVISION)

				if len(backendSplit) > 1 {
					backendReq.Host = backendSplit[1]
				}

				ctx, cancel := context.WithTimeout(backendReq.Context(), s.config.HttpClientTimeout)
				defer cancel()

				// call backend
				resp, err := s.httpClient.Do(backendReq.WithContext(ctx))
				if err != nil {
					s.logger.Error("backend call failed", zap.Error(err), zap.String("url", backend))
					result[index] = fmt.Sprintf("backend %v call failed %v", backend, err)
					// report connection reset or other issues to the client
					statusCode[index] = 418
					return
				}
				defer resp.Body.Close()

				statusCode[index] = resp.StatusCode
				// copy error status from backend and exit
				if resp.StatusCode >= 400 {
					s.logger.Error("backend call failed", zap.Int("status", resp.StatusCode), zap.String("url", backend))
					result[index] = fmt.Sprintf("backend %v response status code %v", backend, resp.StatusCode)
					return
				}

				// forward the received body
				rbody, err := ioutil.ReadAll(resp.Body)
				if err != nil {
					s.logger.Error(
						"reading the backend request body failed",
						zap.Error(err),
						zap.String("url", backend))
					result[index] = fmt.Sprintf("backend %v call failed %v", backend, err)
					return
				}

				s.logger.Debug(
					"payload received from backend",
					zap.String("response", string(rbody)),
					zap.String("url", backend))

				result[index] = string(rbody)
			}(i, b)
		}
		wg.Wait()

		w.Header().Set("X-Color", s.config.UIColor)
		finalCode := 0

		for _, code := range statusCode {
			if code > finalCode {
				finalCode = code
			}
		}
		s.JSONResponseCode(w, r, result, finalCode)

	} else {
		w.Header().Set("X-Color", s.config.UIColor)
		w.WriteHeader(http.StatusAccepted)
		w.Write(body)
	}
}
