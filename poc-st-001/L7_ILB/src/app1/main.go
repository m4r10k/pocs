package main

import (
  "io"
  "net/http"
  "os"
)

func hello(w http.ResponseWriter, r *http.Request) {
  hostname,err := os.Hostname()
  if err != nil {
		panic(err)
	}
  html := "<body style='background-color: green'><h1>App 1; hostname: " + hostname + "</h1></body>"
  io.WriteString(w, html)
}

func main() {
  http.HandleFunc("/", hello)
  http.ListenAndServe(":80", nil)
}
