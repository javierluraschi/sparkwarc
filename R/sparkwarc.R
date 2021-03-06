#' Reads a WARC File into Apache Spark
#'
#' Reads a WARC (Web ARChive) file into Apache Spark using sparklyr.
#'
#' @param sc An active \code{spark_connection}.
#' @param name The name to assign to the newly generated table.
#' @param path The path to the file. Needs to be accessible from the cluster.
#'   Supports the \samp{"hdfs://"}, \samp{"s3n://"} and \samp{"file://"} protocols.
#' @param repartition The number of partitions used to distribute the
#'   generated table. Use 0 (the default) to avoid partitioning.
#' @param memory Boolean; should the data be loaded eagerly into memory? (That
#'   is, should the table be cached?)
#' @param overwrite Boolean; overwrite the table with the given name if it
#'   already exists?
#' @param match_warc include only warc files mathcing this character string.
#' @param match_line include only lines mathcing this character string.
#' @param parser which parser implementation to use? Options are "scala"
#'   or "r" (default).
#' @param ... Additional arguments reserved for future use.
#'
#' @examples
#'
#' \dontrun{
#' library(sparklyr)
#' library(sparkwarc)
#' sc <- spark_connect(master = "local")
#' sdf <- spark_read_warc(
#'   sc,
#'   name = "sample_warc",
#'   path = system.file(file.path("samples", "sample.warc"), package = "sparkwarc"),
#'   memory = FALSE,
#'   overwrite = FALSE
#' )
#'
#' spark_disconnect(sc)
#'}
#'
#' @import DBI
#' @importFrom utils download.file
#' @export
spark_read_warc <- function(sc,
                            name,
                            path,
                            repartition = 0L,
                            memory = TRUE,
                            overwrite = TRUE,
                            match_warc = "",
                            match_line = "",
                            parser = c("r", "scala"),
                            ...) {
  if (overwrite && name %in% dbListTables(sc)) {
    dbRemoveTable(sc, name)
  }

  if (!is.null(parse) && !parser %in% c("r", "scala"))
    stop("Invalid 'parser' value, must be 'r' or 'scala'")

  if (is.null(parser) || parser == "r") {
    paths_df <- data.frame(paths = strsplit(path, ",")[[1]])
    path_repartition <- if (identical(repartition, 0L)) nrow(paths_df) else repartition
    paths_tbl <- sdf_copy_to(
      sc,
      paths_df,
      name = "sparkwarc_paths",
      overwrite = TRUE,
      repartition = as.integer(path_repartition))

    df <- spark_apply(paths_tbl, function(df) {
      entries <- apply(df, 1, function(path) {
        spark_apply_log("is processing warc path ", path)
        temp_warc <- NULL

        if (grepl("s3n://", path)) {
          aws_enabled <- length(system2("which", "aws", stdout = TRUE)) > 0
          temp_warc <- tempfile(fileext = ".warc.gz")

          if (aws_enabled) {
            spark_apply_log("is downloading warc file using aws")
            path <- sub("s3n://", "s3://", path)

            system2("aws", c("s3", "cp", path, temp_warc))
          }
          else {
            spark_apply_log("is downloading warc file using download.file")

            path <- sub("s3n://commoncrawl/", "https://commoncrawl.s3.amazonaws.com/", path)
            download.file(url = path, destfile = temp_warc)
          }

          path <- temp_warc
          spark_apply_log("finished downloading warc file")
        }

        result <- spark_rcpp_read_warc(path, match_warc, match_line)

        if (!is.null(temp_warc)) unlink(temp_warc)

        result
      })

      if (nrow(df) > 1) do.call("rbind", entries) else data.frame(entries)
    }, columns = c(
      tags = "double",
      content = "character"
    )) %>% spark_dataframe()
  }
  else {
    if (nchar(match_warc) > 0) stop("Scala parser does not support 'match_warc'")

    df <- sparklyr::invoke_static(
      sc,
      "SparkWARC.WARC",
      "parse",
      spark_context(sc),
      path,
      match_line,
      as.integer(repartition))
  }

  result_tbl <- sdf_register(df, name)

  if (memory) {
    dbGetQuery(sc, paste("CACHE TABLE", DBI::dbQuoteIdentifier(sc, name)))
    dbGetQuery(sc, paste("SELECT count(*) FROM", DBI::dbQuoteIdentifier(sc, name)))
  }

  result_tbl
}

#' Reads a WARC File into using Rcpp
#'
#' Reads a WARC (Web ARChive) file using Rcpp.
#'
#' @param path The path to the file. Needs to be accessible from the cluster.
#'   Supports the \samp{"hdfs://"}, \samp{"s3n://"} and \samp{"file://"} protocols.
#' @param match_warc include only warc files mathcing this character string.
#' @param match_line include only lines mathcing this character string.
#'
#' @useDynLib sparkwarc, .registration = TRUE
#'
#' @export
spark_rcpp_read_warc <- function(path, match_warc, match_line) {
  rcpp_read_warc(path, filter = match_warc, include = match_line)
}
