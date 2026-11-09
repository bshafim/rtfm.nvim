package main

import (
	"context"
	"fmt"
	"net/http"
	"time"

	eg "golang.org/x/sync/errgroup"
)

func fetch(ctx context.Context, url string) error {
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return err
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return err
	}
	return resp.Body.Close()
}

func main() {
	var g eg.Group
	for _, url := range []string{"https://go.dev", "https://pkg.go.dev"} {
		g.Go(func() error { return fetch(context.Background(), url) })
	}
	fmt.Println(g.Wait())
}
