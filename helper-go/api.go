package main

import (
	"io"
	"net"
	"net/http"
	"strings"
	"time"
)

// Clash API 客户端（替代 nc 手写 HTTP）。
// 从 runtime.yaml 读取 secret 做 Bearer 鉴权；超时 6s 对齐原实现。

var httpClient = &http.Client{
	Timeout: 6 * time.Second,
	Transport: &http.Transport{
		DialContext:       (&net.Dialer{Timeout: 3 * time.Second}).DialContext,
		DisableKeepAlives: true,
	},
}

// apiSecret 从 runtime.yaml 读 secret。
func apiSecret() string {
	cfg, err := loadYAML(runtimeCfg)
	if err != nil {
		return ""
	}
	s, _ := cfg["secret"].(string)
	return s
}

// apiBaseURL 由 runtime.yaml 的 external-controller 推导，失败回退默认。
func apiBaseURL() string {
	cfg, err := loadYAML(runtimeCfg)
	if err != nil {
		return "http://" + apiAddr
	}
	ec, _ := cfg["external-controller"].(string)
	h, p, ok := splitHostPort(ec)
	if !ok {
		h, p = "127.0.0.1", "9090"
	}
	return "http://" + net.JoinHostPort(h, p)
}

// apiRequest 执行 API 请求，返回 (状态码, 响应体, 错误)。
func apiRequest(method, path, body string) (int, string, error) {
	url := apiBaseURL() + path
	var rdr io.Reader
	if body != "" {
		rdr = strings.NewReader(body)
	}
	req, err := http.NewRequest(method, url, rdr)
	if err != nil {
		return 0, "", err
	}
	req.Header.Set("Content-Type", "application/json")
	if s := apiSecret(); s != "" {
		req.Header.Set("Authorization", "Bearer "+s)
	}
	resp, err := httpClient.Do(req)
	if err != nil {
		return 0, "", err
	}
	defer resp.Body.Close()
	b, err := io.ReadAll(io.LimitReader(resp.Body, 4<<20))
	if err != nil {
		return resp.StatusCode, "", err
	}
	return resp.StatusCode, string(b), nil
}

// apiOK 探活：GET /version 返回 200。
func apiOK() bool {
	code, _, err := apiRequest("GET", "/version", "")
	return err == nil && code == 200
}
