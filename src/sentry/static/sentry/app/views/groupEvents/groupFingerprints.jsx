import React from 'react';
import Reflux from 'reflux';

import {t} from '../../locale';
import ApiMixin from '../../mixins/apiMixin';
import GroupState from '../../mixins/groupState';
import GroupingActions from '../../actions/groupingActions';
import GroupingStore from '../../stores/groupingStore';
import LoadingError from '../../components/loadingError';
import LoadingIndicator from '../../components/loadingIndicator';
import MergedList from '../groupSimilar/mergedList';

const GroupEvents = React.createClass({
  mixins: [ApiMixin, GroupState, Reflux.listenTo(GroupingStore, 'onGroupingUpdate')],

  getInitialState() {
    let queryParams = this.props.location.query;
    return {
      mergedItems: [],
      loading: true,
      error: false,
      query: queryParams.query || ''
    };
  },

  componentWillMount() {
    this.fetchData();
  },

  componentWillReceiveProps(nextProps) {
    if (
      nextProps.params.groupId !== this.props.params.groupId ||
      nextProps.location.search !== this.props.location.search
    ) {
      let queryParams = nextProps.location.query;
      this.setState(
        {
          query: queryParams.query
        },
        this.fetchData
      );
    }
  },

  onGroupingUpdate({mergedItems, mergedLinks, loading, error}) {
    if (mergedItems) {
      this.setState({
        mergedItems,
        mergedLinks,
        loading: typeof loading !== 'undefined' ? loading : false,
        error: typeof error !== 'undefined' ? error : false
      });
    }
  },

  getEndpoint(type = 'hashes') {
    let params = this.props.params;
    let queryParams = {
      ...this.props.location.query,
      limit: 50,
      query: this.state.query
    };

    return `/issues/${params.groupId}/${type}/?${jQuery.param(queryParams)}`;
  },

  fetchData() {
    GroupingActions.fetch([
      {
        endpoint: this.getEndpoint('hashes'),
        dataKey: 'merged',
        queryParams: this.props.location.query
      }
    ]);
  },

  render() {
    let {orgId, projectId, groupId} = this.props.params;
    let hasFingerprints = this.state.mergedItems.length > 0;

    if (this.state.loading) {
      return <LoadingIndicator />;
    }

    if (this.state.error) {
      return <LoadingError message={this.state.error} onRetry={this.fetchData} />;
    }

    if (!hasFingerprints) {
      return (
        <div className="box empty-stream">
          <span className="icon icon-exclamation" />
          <p>{t("There don't seem to be any events yet.")}</p>
        </div>
      );
    }

    return (
      <MergedList
        items={this.state.mergedItems}
        orgId={orgId}
        projectId={projectId}
        groupId={groupId}
        pageLinks={this.state.mergedLinks}
        busyMap={this.state.busy}
        hiddenMap={this.state.hidden}
      />
    );
  }
});

export default GroupEvents;
