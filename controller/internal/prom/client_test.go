package prom

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"
)

func serve(t *testing.T, body string) *Client {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/api/v1/query" {
			t.Errorf("unexpected path %s", r.URL.Path)
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(body))
	}))
	t.Cleanup(srv.Close)
	return New(srv.URL)
}

func TestQueryScalarSumsVector(t *testing.T) {
	c := serve(t, `{"status":"success","data":{"resultType":"vector","result":[
		{"metric":{"pod":"a"},"value":[1700000000,"12"]},
		{"metric":{"pod":"b"},"value":[1700000000,"7.5"]}]}}`)
	got, err := c.QueryScalar(context.Background(), "x")
	if err != nil {
		t.Fatal(err)
	}
	if got != 19.5 {
		t.Fatalf("got %v, want 19.5", got)
	}
}

func TestQueryScalarEmptyVectorIsZero(t *testing.T) {
	c := serve(t, `{"status":"success","data":{"resultType":"vector","result":[]}}`)
	got, err := c.QueryScalar(context.Background(), "x")
	if err != nil || got != 0 {
		t.Fatalf("got %v, %v; want 0, nil", got, err)
	}
}

func TestQueryScalarNaNIsZero(t *testing.T) {
	c := serve(t, `{"status":"success","data":{"resultType":"scalar","result":[1700000000,"NaN"]}}`)
	got, err := c.QueryScalar(context.Background(), "x")
	if err != nil || got != 0 {
		t.Fatalf("got %v, %v; want 0, nil", got, err)
	}
}

func TestQueryScalarError(t *testing.T) {
	c := serve(t, `{"status":"error","errorType":"bad_data","error":"parse error"}`)
	if _, err := c.QueryScalar(context.Background(), "x"); err == nil {
		t.Fatal("expected error")
	}
}
