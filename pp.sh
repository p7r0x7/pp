#!/bin/sh

# SPDX-License-Identifier: Apache-2.0
# Copyright © 2025 @p7r0x7 <mattrbonnette@pm.me> All rights reserved.

#
#    VPXL's PP is an FFmpeg filterchain that optimizes the format and content of videos for encoding efficiency.
#    Only perceptible content is preserved (this filter is extremely conservative while remaining quite effective).
#    This filter should not be used on very low resolution content or prior to ultra high fidelity transcoding.
#

cli() {
    help() {
        printf '%s\n' \
            'Usage: pp.sh <video> [-y4m|-yuv|-mkv|-nut|-avi|-av1an] [-crop w:h] [-trim start:end] [-ffmpeg path]' \
            '    *) Operates on the first video in the file and its metadata.' \
            '    *) For -av1an, use "-f -vf $(pp video.mp4 -av1an ...)".' \
            '    *) Results are streamed to /dev/stdout.'
        exit $1
    }
    [ $# -gt 0 ] || help 0; set -exu; umask 0022

    video="$1" format=yuv4mpegpipe crop='' trim='' ffmpeg=''; shift
    while [ $# -gt 0 ]; do
        case "$1" in
            -ffmpeg) [ $# -ge 2 ] || help 1; ffmpeg="$2 -hide_banner -hwaccel auto"; shift 2 ;;
            -trim) [ $# -ge 2 ] || help 1; trim=$2; shift 2 ;;
            -crop) [ $# -ge 2 ] || help 1; crop=$2; shift 2 ;;
            -av1an|-nut|-avi) format=${1#-}; shift ;;
            -y4m) format=yuv4mpegpipe; shift ;;
            -mkv) format=matroska; shift ;;
            -yuv) format=rawvideo; shift ;;
            *) help 1 ;;
        esac
    done
    [ "$ffmpeg" = '' ] && ffmpeg="$(command -v ffmpeg) -hide_banner -hwaccel auto"
    placebo="libplacebo=dithering=none" ffprobe="$(command -v ffprobe) -v error"
    [ -f /tmp/ffmpeg_fmts.txt ] || $ffmpeg -pix_fmts >/tmp/ffmpeg_fmts.txt 2>&1 &
}

pp() {
    eval "$(
        $ffprobe -select_streams v:0 -of default=nw=1:nk=1 "$video" -show_entries \
            stream=width,pix_fmt,color_range,color_space,color_transfer,color_primaries,r_frame_rate | \
        awk '
            NR==1 { printf "width=%s ", $0 } NR==2 { printf "fmt=%s ", $0 } NR==3 { printf "range=%s ", $0 }
            NR==4 { printf "space=%s ", $0 } NR==5 { printf "txfr=%s ", $0 } NR==6 { printf "primes=%s ", $0 }
            NR==7 { printf "fps=%s\n", $0 }
        '
    )"
    if [ $space$txfr$primes = unknownunknownunknown ]; then
        case $range in pc|full|jpeg) ;; *) space=bt709 txfr=bt709 primes=bt709 range=tv ;; esac
    fi
    case $fps in */*) ;; *) fps=$fps/1;; esac
    wait

    isalpha() {
        fmts=$(awk '$3 == 2 || $3 == 4 { printf "|%s", $2 }' /tmp/ffmpeg_fmts.txt)
        case "$fmt" in ${fmts#|}) return 0 ;; *) return 1 ;; esac
    }
    isalpha "$video" && fmt1=yuva444p16le fmt2=yuva420p10le || fmt1=yuv444p16le fmt2=yuv420p10le

    detelecine= deinterlace= #"bwdif=mode=0:deint=1,"

    [ "$crop" != '' ] && crop="crop=$crop,"; [ "$trim" != '' ] && trim="trim=$trim,"

    if false; then
        decimate="mpdecimate=hi=256:lo=64:frac=0.1,"
    else
        decimate="
            freezedetect=n=0:d=$(awk -v r="$fps" 'BEGIN { split(r, a, "/"); printf "%.9f\n", a[1]/a[2] }'),
            metadata=add:lavfi.freezedetect.freeze_start:n/a,
            metadata=select:lavfi.freezedetect.freeze_start:n/a:same_str,"
    fi

    filterchain="$(printf %s "
        setparams=colorspace=$space:color_trc=$txfr:color_primaries=$primes:range=$range,
        $detelecine$deinterlace
        $trim$crop

        zscale=m=ictcp:t=smpte2084:p=bt2020:r=pc:f=lanczos:param_a=16,format=$fmt1,
        setparams=colorspace=ictcp:color_trc=smpte2084:color_primaries=bt2020:range=pc,
        bilateral,
        $placebo:deband=1:deband_radius=32:deband_iterations=8:deband_threshold=1.5:deband_grain=0,
        $decimate

        zscale=m=$space:t=$txfr:p=$primes:r=tv:f=lanczos:param_a=16,format=$fmt2,
        setparams=colorspace=$space:color_trc=$txfr:color_primaries=$primes:range=tv,
        fps=fps=$fps:eof_action=pass,settb=${fps#*/}/${fps%%/*},setpts=PTS-STARTPTS" | tr -d '[:space:]') -fps_mode cfr"

    if [ $format = av1an ]; then printf %s "$filterchain"; return; fi

    $ffmpeg -i "$video" -map 0:v -vf $filterchain -c:v rawvideo -strict -1 -f $format -
}

cli "$@"; pp
