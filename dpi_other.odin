#+build !windows
package main

// Only Windows stretches a window behind the application's back.
claim_dpi_awareness :: proc() {}
