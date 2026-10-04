// Package prom is a minimal Prometheus HTTP API client for instant queries.
// It avoids pulling the full Prometheus client library into the controller.
package prom

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"
)

// Client queries a Prometheus server.
type Client struct {
	BaseURL    string
	HTTPClient *http.Client
}

// New returns a client with a sensible timeout.
func New(baseURL string) *Client {
	return &Client{
		BaseURL:    strings.TrimRight(baseURL, "/"),
		HTTPClient: &http.Client{Timeout: 10 * time.Second},
	}
}

type apiResponse struct {
	Status    string `json:"status"`
	ErrorType string `json:"errorType"`
	Error     string `json:"error"`
	Data      struct {
		ResultType string          `json:"resultType"`
		Result     json.RawMessage `json:"result"`
	} `json:"data"`
}

type vectorSample struct {
	Metric map[string]string `json:"metric"`
	Value  [2]any            `json:"value"`
}

// QueryScalar runs an instant query and returns the sum of all returned
// samples. An empty vector returns 0, which is what we want when the target
// has no running pods yet.
func (c *Client) QueryScalar(ctx context.Context, query string) (float64, error) {
	u := c.BaseURL + "/api/v1/query?query=" + url.QueryEscape(query)
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return 0, err
	}
	resp, err := c.HTTPClient.Do(req)
	if err != nil {
		return 0, fmt.Errorf("prometheus request: %w", err)
	}
	defer resp.Body.Close()

	var body apiResponse
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		return 0, fmt.Errorf("decode prometheus response (HTTP %d): %w", resp.StatusCode, err)
	}
	if body.Status != "success" {
		return 0, fmt.Errorf("prometheus %s: %s", body.ErrorType, body.Error)
	}

	switch body.Data.ResultType {
	case "vector":
		var samples []vectorSample
		if err := json.Unmarshal(body.Data.Result, &samples); err != nil {
			return 0, fmt.Errorf("decode vector: %w", err)
		}
		var total float64
		for _, s := range samples {
			v, err := parseValue(s.Value)
			if err != nil {
				return 0, err
			}
			total += v
		}
		return total, nil
	case "scalar":
		var pair [2]any
		if err := json.Unmarshal(body.Data.Result, &pair); err != nil {
			return 0, fmt.Errorf("decode scalar: %w", err)
		}
		return parseValue(pair)
	default:
		return 0, fmt.Errorf("unsupported result type %q (use sum() to return a vector)", body.Data.ResultType)
	}
}

func parseValue(pair [2]any) (float64, error) {
	s, ok := pair[1].(string)
	if !ok {
		return 0, fmt.Errorf("unexpected sample value %v", pair[1])
	}
	v, err := strconv.ParseFloat(s, 64)
	if err != nil {
		return 0, fmt.Errorf("parse sample %q: %w", s, err)
	}
	// NaN shows up when a ratio has a zero denominator; treat it as no load.
	if v != v {
		return 0, nil
	}
	return v, nil
}
